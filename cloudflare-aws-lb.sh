#!/bin/bash

REGION="ap-southeast-2"
EB_ENV_NAME="MaruMoodle-Prod-v2"

echo "Fetching Load Balancer Security Group..."

# Retrieve the ALB ARN associated with the EB environment
ALB_ARN=$(aws elasticbeanstalk describe-environment-resources \
  --environment-name $EB_ENV_NAME \
  --region $REGION \
  --query "EnvironmentResources.LoadBalancers[0].Name" \
  --output text)

if [ "$ALB_ARN" == "None" ] || [ -z "$ALB_ARN" ]; then
    echo "Error: Could not find the Application Load Balancer."
    exit 1
fi

# Retrieve the Security Group ID attached to the ALB
ALB_SG_ID=$(aws elbv2 describe-load-balancers \
  --load-balancer-arns $ALB_ARN \
  --region $REGION \
  --query "LoadBalancers[0].SecurityGroups[0]" \
  --output text)

echo "Load Balancer SG: $ALB_SG_ID"
echo "Revoking global internet access (0.0.0.0/0 and ::/0)..."

aws ec2 revoke-security-group-ingress --region $REGION --group-id $ALB_SG_ID --protocol tcp --port 80 --cidr 0.0.0.0/0 2>/dev/null
aws ec2 revoke-security-group-ingress --region $REGION --group-id $ALB_SG_ID --protocol tcp --port 443 --cidr 0.0.0.0/0 2>/dev/null
aws ec2 revoke-security-group-ingress --region $REGION --group-id $ALB_SG_ID --protocol tcp --port 80 --ipv6-cidr ::/0 2>/dev/null
aws ec2 revoke-security-group-ingress --region $REGION --group-id $ALB_SG_ID --protocol tcp --port 443 --ipv6-cidr ::/0 2>/dev/null

echo "Applying Cloudflare IPv4 ranges..."
for ip in $(curl -s https://www.cloudflare.com/ips-v4); do
  aws ec2 authorize-security-group-ingress --region $REGION --group-id $ALB_SG_ID --protocol tcp --port 80 --cidr $ip 2>/dev/null
  aws ec2 authorize-security-group-ingress --region $REGION --group-id $ALB_SG_ID --protocol tcp --port 443 --cidr $ip 2>/dev/null
done

echo "Applying Cloudflare IPv6 ranges..."
for ip in $(curl -s https://www.cloudflare.com/ips-v6); do
  aws ec2 authorize-security-group-ingress --region $REGION --group-id $ALB_SG_ID --protocol tcp --port 80 --ipv6-cidr $ip 2>/dev/null
  aws ec2 authorize-security-group-ingress --region $REGION --group-id $ALB_SG_ID --protocol tcp --port 443 --ipv6-cidr $ip 2>/dev/null
done

echo "Cloudflare lockdown complete!"
