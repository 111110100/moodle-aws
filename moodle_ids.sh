#!/bin/bash
# Exit immediately on failure, pipe failures
set -e
set -o pipefail

ENV_NAME="MaruMoodle-Prod-v2"
REGION="ap-southeast-2"
WAF_ACL_NAME="Moodle-WAF-WebACL"
export AWS_PAGER=""

# Cleanup temporary files on exit
trap 'rm -f waf-rules.json' EXIT

echo "=================================================================="
echo "          PROVISIONING INTRUSION DETECTION & WAF SECURITY         "
echo "=================================================================="

# ------------------------------------------------------------------------------
# STEP 1: AWS GuardDuty (Account & Infrastructure IDS)
# ------------------------------------------------------------------------------
echo "Checking GuardDuty status in $REGION..."
DETECTOR_ID=$(aws guardduty list-detectors \
  --region "$REGION" \
  --query "DetectorIds[0]" \
  --output text)

if [ -z "$DETECTOR_ID" ] || [ "$DETECTOR_ID" == "None" ]; then
    echo "   -> Enabling AWS GuardDuty..."
    DETECTOR_ID=$(aws guardduty create-detector \
      --enable \
      --finding-publishing-frequency FIFTEEN_MINUTES \
      --region "$REGION" \
      --query 'DetectorId' \
      --output text)
    echo "   -> GuardDuty enabled with Detector ID: $DETECTOR_ID"
else
    echo "   -> GuardDuty Detector already active: $DETECTOR_ID"
fi

echo "   -> Enabling GuardDuty S3 Protection..."
aws guardduty update-detector \
  --detector-id "$DETECTOR_ID" \
  --data-sources '{"S3Logs": {"Enable": true}}' \
  --region "$REGION"
echo "   -> S3 Protection active."

# ------------------------------------------------------------------------------
# STEP 2: AWS WAF v2 (Web Application Layer IDS/IPS)
# ------------------------------------------------------------------------------
echo "Checking existing WAF WebACL ($WAF_ACL_NAME)..."
WEB_ACL_ARN=$(aws wafv2 list-web-acls \
  --scope REGIONAL \
  --region "$REGION" \
  --query "WebACLs[?Name=='${WAF_ACL_NAME}'].ARN | [0]" \
  --output text)

if [ -z "$WEB_ACL_ARN" ] || [ "$WEB_ACL_ARN" == "None" ]; then
    echo "   -> Creating WAF WebACL rules..."
    cat <<EOF > waf-rules.json
{
  "Name": "${WAF_ACL_NAME}",
  "Scope": "REGIONAL",
  "DefaultAction": { "Allow": {} },
  "VisibilityConfig": {
    "SampledRequestsEnabled": true,
    "CloudWatchMetricsEnabled": true,
    "MetricName": "MoodleWAFMetrics"
  },
  "Rules": [
    {
      "Name": "AWSManagedRulesCommonRuleSet",
      "Priority": 1,
      "Statement": {
        "ManagedRuleGroupStatement": {
          "VendorName": "AWS",
          "Name": "AWSManagedRulesCommonRuleSet"
        }
      },
      "OverrideAction": { "None": {} },
      "VisibilityConfig": {
        "SampledRequestsEnabled": true,
        "CloudWatchMetricsEnabled": true,
        "MetricName": "AWSCommonRules"
      }
    },
    {
      "Name": "AWSManagedRulesSQLiRuleSet",
      "Priority": 2,
      "Statement": {
        "ManagedRuleGroupStatement": {
          "VendorName": "AWS",
          "Name": "AWSManagedRulesSQLiRuleSet"
        }
      },
      "OverrideAction": { "None": {} },
      "VisibilityConfig": {
        "SampledRequestsEnabled": true,
        "CloudWatchMetricsEnabled": true,
        "MetricName": "AWSSQLiRules"
      }
    }
  ]
}
EOF

    WEB_ACL_ARN=$(aws wafv2 create-web-acl \
      --cli-input-json file://waf-rules.json \
      --region "$REGION" \
      --query 'Summary.ARN' \
      --output text)
    echo "   -> Created WAF WebACL: $WEB_ACL_ARN"
else
    echo "   -> Existing WAF WebACL found: $WEB_ACL_ARN"
fi

# ------------------------------------------------------------------------------
# STEP 3: Associate WAF with Elastic Beanstalk ALB
# ------------------------------------------------------------------------------
echo "Resolving ALB ARN for environment $ENV_NAME..."
ALB_ARN=$(aws elasticbeanstalk describe-environment-resources \
  --environment-name "$ENV_NAME" \
  --region "$REGION" \
  --query "EnvironmentResources.LoadBalancers[0].Name" \
  --output text)

if [ -z "$ALB_ARN" ] || [ "$ALB_ARN" == "None" ]; then
    echo "ERROR: Could not resolve Load Balancer ARN from Elastic Beanstalk environment $ENV_NAME."
    exit 1
fi

echo "   -> Load Balancer target: $ALB_ARN"
echo "   -> Associating WAF WebACL to ALB..."
aws wafv2 associate-web-acl \
  --web-acl-arn "$WEB_ACL_ARN" \
  --resource-arn "$ALB_ARN" \
  --region "$REGION"

echo "   -> WAF attached successfully."

# ------------------------------------------------------------------------------
# STEP 4: Inspect Active Security Findings
# ------------------------------------------------------------------------------
echo "Checking active GuardDuty findings..."
FINDING_IDS=$(aws guardduty list-findings \
  --detector-id "$DETECTOR_ID" \
  --region "$REGION" \
  --finding-criteria '{"Criterion": {"service.archived": {"Eq": ["false"]}}}' \
  --query "FindingIds" \
  --output json)

if [ "$FINDING_IDS" != "[]" ] && [ -n "$FINDING_IDS" ]; then
    echo "   -> Active security findings detected:"
    aws guardduty get-findings \
      --detector-id "$DETECTOR_ID" \
      --region "$REGION" \
      --finding-ids $(echo "$FINDING_IDS" | jq -r '.[]') \
      --query "Findings[*].[Severity, Title, Type, Service.Action.ActionType]" \
      --output table
else
    echo "   -> No unarchived GuardDuty findings detected."
fi

echo "=================================================================="
echo "          IDS & WAF DEPLOYMENT COMPLETE AND ACTIVE                "
echo "=================================================================="
