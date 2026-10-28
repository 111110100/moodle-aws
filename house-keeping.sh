#!/bin/bash
# Exit immediately if a command fails
set -e
set -o pipefail

# ==============================================================================
# CONFIGURATION VARIABLES
# ==============================================================================
# 1. Elastic Beanstalk Application Version Retention
# Set EITHER EB_MAX_COUNT OR EB_MAX_DAYS. Leave the other empty ("").
# They cannot both be empty, and they cannot both have values.
EB_MAX_COUNT="20"       # e.g., Keep only the last 20 application versions
EB_MAX_DAYS=""          # e.g., Or leave empty if using max_count

# 2. S3 Log & Object Expiration (Days)
# Set how long (in days) to retain log objects and deployment packages in S3 before deletion.
S3_LOG_EXPIRATION_DAYS="30"

# 3. Identifiers
REGION="ap-southeast-2"
APP_NAME="MaruMoodleLMS"

# Disable paging
export AWS_PAGER=""

# ==============================================================================
# VALIDATION
# ==============================================================================
echo "Validating configuration parameters..."
if [ -z "$EB_MAX_COUNT" ] && [ -z "$EB_MAX_DAYS" ]; then
    echo "ERROR: Both EB_MAX_COUNT and EB_MAX_DAYS cannot be empty. Please configure one."
    exit 1
fi
if [ -n "$EB_MAX_COUNT" ] && [ -n "$EB_MAX_DAYS" ]; then
    echo "ERROR: You cannot specify both EB_MAX_COUNT and EB_MAX_DAYS simultaneously."
    exit 1
fi

# Construct standard Elastic Beanstalk S3 bucket name: elasticbeanstalk-<region>-<account-id>
echo "Resolving Elastic Beanstalk S3 bucket name..."
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
S3_BUCKET_NAME="elasticbeanstalk-${REGION}-${ACCOUNT_ID}"

# Verify the bucket exists in AWS S3
if ! aws s3api head-bucket --bucket "$S3_BUCKET_NAME" --region "$REGION" 2>/dev/null; then
    echo "Searching for fallback Elastic Beanstalk S3 bucket..."
    S3_BUCKET_NAME=$(aws s3api list-buckets \
      --query "Buckets[?contains(Name, 'elasticbeanstalk-${REGION}')].Name|[0]" \
      --output text)
fi

if [ -z "$S3_BUCKET_NAME" ] || [ "$S3_BUCKET_NAME" == "None" ]; then
    echo "ERROR: Could not automatically detect Elastic Beanstalk S3 bucket."
    exit 1
fi

echo "   -> Target S3 Bucket: $S3_BUCKET_NAME"
echo "================================================================================"

# ==============================================================================
# 1. ELASTIC BEANSTALK APPLICATION VERSION LIFECYCLE CONFIGURATION
# ==============================================================================
echo "Checking existing Elastic Beanstalk Application Version Lifecycle policy..."
aws elasticbeanstalk describe-application-versions \
  --application-name "$APP_NAME" \
  --region "$REGION" >/dev/null 2>&1 && echo "   -> Application found." || true

# Construct JSON lifecycle payload based on user configuration
if [ -n "$EB_MAX_COUNT" ]; then
    LIFECYCLE_JSON=$(cat <<EOF
{
  "ServiceRole": "arn:aws:iam::${ACCOUNT_ID}:role/service-role/aws-elasticbeanstalk-service-role",
  "VersionLifecycleConfig": {
    "MaxAgeRule": {
      "Enabled": false
    },
    "MaxCountRule": {
      "Enabled": true,
      "MaxCount": $EB_MAX_COUNT,
      "DeleteSourceFromS3": true
    }
  }
}
EOF
)
else
    LIFECYCLE_JSON=$(cat <<EOF
{
  "ServiceRole": "arn:aws:iam::${ACCOUNT_ID}:role/service-role/aws-elasticbeanstalk-service-role",
  "VersionLifecycleConfig": {
    "MaxAgeRule": {
      "Enabled": true,
      "MaxAgeInDays": $EB_MAX_DAYS,
      "DeleteSourceFromS3": true
    },
    "MaxCountRule": {
      "Enabled": false
    }
  }
}
EOF
)
fi

echo "Applying Elastic Beanstalk Application Lifecycle policy..."
aws elasticbeanstalk update-application-resource-lifecycle \
  --application-name "$APP_NAME" \
  --resource-lifecycle-config "$LIFECYCLE_JSON" \
  --region "$REGION"
echo "   -> EB Version Lifecycle successfully applied."

# ==============================================================================
# 2. S3 BUCKET LIFECYCLE POLICY CONFIGURATION
# ==============================================================================
echo "Checking existing S3 Bucket Lifecycle configuration for $S3_BUCKET_NAME..."
EXISTING_S3_RULES=$(aws s3api get-bucket-lifecycle-configuration \
  --bucket "$S3_BUCKET_NAME" \
  --region "$REGION" 2>/dev/null || echo "No existing S3 lifecycle rules found.")

echo "   -> Current S3 Rules:"
echo "$EXISTING_S3_RULES"

# Create lifecycle JSON configuration file
cat <<EOF > s3-lifecycle.json
{
  "Rules": [
    {
      "ID": "DeleteOldLogsAndDeployments",
      "Status": "Enabled",
      "Filter": {
        "Prefix": ""
      },
      "Expiration": {
        "Days": $S3_LOG_EXPIRATION_DAYS
      },
      "AbortIncompleteMultipartUpload": {
        "DaysAfterInitiation": 7
      }
    }
  ]
}
EOF

echo "Applying updated S3 Bucket Lifecycle configuration..."
aws s3api put-bucket-lifecycle-configuration \
  --bucket "$S3_BUCKET_NAME" \
  --lifecycle-configuration file://s3-lifecycle.json \
  --region "$REGION"

rm -f s3-lifecycle.json
echo "   -> S3 Lifecycle policy successfully applied."

echo "================================================================================"
echo "House-keeping complete! Resource cleanup policies are active."
