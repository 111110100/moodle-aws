#!/bin/bash
set -eou pipefail

# Disable AWS CLI interactive terminal pager
export AWS_PAGER=""

REGION="ap-southeast-2"
EB_ENV_NAME="MaruMoodle-Prod-v2"

# ----------------------------------------------------------------------
# HELPER FUNCTIONS
# ----------------------------------------------------------------------

revoke_rule() {
  local port=$1
  local cidr=$2
  local type=$3 # "ipv4" or "ipv6"

  if [ "$type" == "ipv6" ]; then
    if aws ec2 revoke-security-group-ingress --region "$REGION" --group-id "$ALB_SG_ID" --ip-permissions "IpProtocol=tcp,FromPort=$port,ToPort=$port,Ipv6Ranges=[{CidrIpv6=$cidr}]" --output text 2>/dev/null; then
      echo "  -> [REVOKED] Port $port: $cidr (IPv6)"
    else
      echo "  -> [SKIP] Port $port: $cidr (IPv6 rule was not present)"
    fi
  else
    if aws ec2 revoke-security-group-ingress --region "$REGION" --group-id "$ALB_SG_ID" --protocol tcp --port "$port" --cidr "$cidr" --output text 2>/dev/null; then
      echo "  -> [REVOKED] Port $port: $cidr"
    else
      echo "  -> [SKIP] Port $port: $cidr (IPv4 rule was not present)"
    fi
  fi
}

authorize_rule() {
  local port=$1
  local cidr=$2
  local type=$3 # "ipv4" or "ipv6"
  local out
  local status=0

  if [ "$type" == "ipv6" ]; then
    out=$(aws ec2 authorize-security-group-ingress --region "$REGION" --group-id "$ALB_SG_ID" --ip-permissions "IpProtocol=tcp,FromPort=$port,ToPort=$port,Ipv6Ranges=[{CidrIpv6=$cidr}]" --output text 2>&1) || status=$?
  else
    out=$(aws ec2 authorize-security-group-ingress --region "$REGION" --group-id "$ALB_SG_ID" --protocol tcp --port "$port" --cidr "$cidr" --output text 2>&1) || status=$?
  fi

  if [ $status -eq 0 ]; then
    echo "  -> [ADDED] Port $port: $cidr"
  elif echo "$out" | grep -q "InvalidPermission.Duplicate"; then
    echo "  -> [EXISTS] Port $port: $cidr (Already authorized)"
  else
    echo "  -> [ERROR] Port $port: $cidr failed - $out"
  fi
}

# ----------------------------------------------------------------------
# MAIN EXECUTION
# ----------------------------------------------------------------------

echo "Fetching Load Balancer Security Group for '$EB_ENV_NAME'..."

# 1. Retrieve the Load Balancer identifier from Elastic Beanstalk
ALB_ARN=$(aws elasticbeanstalk describe-environment-resources \
  --environment-name "$EB_ENV_NAME" \
  --region "$REGION" \
  --query "EnvironmentResources.LoadBalancers[0].Name" \
  --output text)

if [ "$ALB_ARN" == "None" ] || [ -z "$ALB_ARN" ]; then
  echo "Error: Could not find any Load Balancer attached to $EB_ENV_NAME."
  exit 1
fi

# 2. Try fetching from ELBv2 (Application Load Balancer)
if [[ "$ALB_ARN" == arn:aws:elasticloadbalancing* ]]; then
  ALB_SG_ID=$(aws elbv2 describe-load-balancers \
    --load-balancer-arns "$ALB_ARN" \
    --region "$REGION" \
    --query "LoadBalancers[0].SecurityGroups[0]" \
    --output text 2>/dev/null || true)
else
  ALB_SG_ID=$(aws elbv2 describe-load-balancers \
    --names "$ALB_ARN" \
    --region "$REGION" \
    --query "LoadBalancers[0].SecurityGroups[0]" \
    --output text 2>/dev/null || true)
fi

# 3. Fallback to Classic Load Balancer (ELBv1) if ELBv2 returned empty
if [ -z "$ALB_SG_ID" ] || [ "$ALB_SG_ID" == "None" ]; then
  echo "Notice: Not found via ELBv2. Attempting fallback to Classic Load Balancer (ELBv1)..."
  ALB_SG_ID=$(aws elb describe-load-balancers \
    --load-balancer-names "$ALB_ARN" \
    --region "$REGION" \
    --query "LoadBalancerDescriptions[0].SecurityGroups[0]" \
    --output text 2>/dev/null || true)
fi

if [ -z "$ALB_SG_ID" ] || [ "$ALB_SG_ID" == "None" ]; then
  echo "Error: Could not retrieve Security Group ID for Load Balancer '$ALB_ARN'."
  exit 1
fi

echo "Target Security Group: $ALB_SG_ID"
echo "---------------------------------------------------------------------"
echo "Phase 1: Revoking global internet access..."

revoke_rule 80 "0.0.0.0/0" "ipv4"
revoke_rule 443 "0.0.0.0/0" "ipv4"
revoke_rule 80 "::/0" "ipv6"
revoke_rule 443 "::/0" "ipv6"

echo "---------------------------------------------------------------------"
echo "Phase 2: Applying Cloudflare IPv4 ranges..."
IPV4_RANGES=$(curl -sSLf -A "Mozilla/5.0" https://www.cloudflare.com/ips-v4)

if [ -z "$IPV4_RANGES" ]; then
  echo "Error: Failed to fetch IPv4 ranges from Cloudflare."
  exit 1
fi

for ip in $IPV4_RANGES; do
  authorize_rule 80 "$ip" "ipv4"
  authorize_rule 443 "$ip" "ipv4"
done

echo "---------------------------------------------------------------------"
echo "Phase 3: Applying Cloudflare IPv6 ranges..."
IPV6_RANGES=$(curl -sSLf -A "Mozilla/5.0" https://www.cloudflare.com/ips-v6)

if [ -z "$IPV6_RANGES" ]; then
  echo "Error: Failed to fetch IPv6 ranges from Cloudflare."
  exit 1
fi

for ip in $IPV6_RANGES; do
  authorize_rule 80 "$ip" "ipv6"
  authorize_rule 443 "$ip" "ipv6"
done

echo "---------------------------------------------------------------------"
echo "Cloudflare lockdown complete for Security Group $ALB_SG_ID!"
