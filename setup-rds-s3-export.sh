#!/bin/bash
# Exit immediately if a command fails, but allow specific expected duplicates (like IAM roles/rules) to bypass.
set -e
set -o pipefail

export LOG_FILE="setup_rds_export.log"
export REGION="ap-southeast-2"
export DB_CLUSTER_ID="maru-moodle-db"
export S3_BUCKET_NAME="maru-moodle-data-2026"
export KMS_ALIAS="alias/moodle-rds-s3-export-key"
export S3_PREFIX="RDS_Backups/"

> $LOG_FILE
echo "Starting Automated RDS Snapshot Export to S3 Provisioning..." | tee -a $LOG_FILE
echo "================================================================" | tee -a $LOG_FILE

echo "1. Fetching AWS Account Details & KMS Key..." | tee -a $LOG_FILE
export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export KMS_KEY_ARN=$(aws kms describe-key --key-id $KMS_ALIAS --region $REGION --query "KeyMetadata.Arn" --output text 2>>$LOG_FILE || true)

if [ -z "$KMS_KEY_ARN" ] || [ "$KMS_KEY_ARN" == "None" ]; then
    echo "ERROR: KMS Key $KMS_ALIAS not found. Please verify it exists." | tee -a $LOG_FILE
    exit 1
fi
echo "   -> KMS Key ARN: $KMS_KEY_ARN" | tee -a $LOG_FILE


echo "2. Setting up RDS Export IAM Role..." | tee -a $LOG_FILE
cat << 'EOF' > rds-s3-trust-policy.json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": { "Service": "export.rds.amazonaws.com" },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF

aws iam create-role   --role-name rds-s3-export-role   --assume-role-policy-document file://rds-s3-trust-policy.json 2>>$LOG_FILE || echo "   -> Export Role already exists." | tee -a $LOG_FILE

cat << EOF > rds-s3-export-policy.json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "s3:ListBucket",
        "s3:GetBucketLocation"
      ],
      "Resource": "arn:aws:s3:::$S3_BUCKET_NAME"
    },
    {
      "Effect": "Allow",
      "Action": [
        "s3:PutObject",
        "s3:GetObject",
        "s3:DeleteObject"
      ],
      "Resource": "arn:aws:s3:::$S3_BUCKET_NAME/*"
    },
    {
      "Effect": "Allow",
      "Action": [
        "kms:Encrypt",
        "kms:Decrypt",
        "kms:ReEncrypt*",
        "kms:GenerateDataKey*",
        "kms:CreateGrant",
        "kms:DescribeKey"
      ],
      "Resource": "$KMS_KEY_ARN"
    }
  ]
}
EOF

aws iam put-role-policy   --role-name rds-s3-export-role   --policy-name RDSS3ExportPolicy   --policy-document file://rds-s3-export-policy.json 2>>$LOG_FILE


echo "3. Setting up Lambda Execution IAM Role..." | tee -a $LOG_FILE
cat << 'EOF' > lambda-trust-policy.json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": { "Service": "lambda.amazonaws.com" },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF

aws iam create-role   --role-name rds-snapshot-exporter-lambda-role   --assume-role-policy-document file://lambda-trust-policy.json 2>>$LOG_FILE || echo "   -> Lambda Role already exists." | tee -a $LOG_FILE

aws iam attach-role-policy   --role-name rds-snapshot-exporter-lambda-role   --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole 2>>$LOG_FILE || true

cat << EOF > lambda-rds-policy.json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "rds:DescribeDBSnapshots",
        "rds:DescribeDBClusterSnapshots",
        "rds:StartExportTask",
        "iam:PassRole"
      ],
      "Resource": "*"
    },
    {
      "Effect": "Allow",
      "Action": [
        "kms:CreateGrant",
        "kms:DescribeKey"
      ],
      "Resource": "$KMS_KEY_ARN"
    }
  ]
}
EOF

aws iam put-role-policy   --role-name rds-snapshot-exporter-lambda-role   --policy-name LambdaRDSAndKMSExportPolicy   --policy-document file://lambda-rds-policy.json 2>>$LOG_FILE


echo "4. Packaging Lambda Python Code..." | tee -a $LOG_FILE
cat << 'EOF' > index.py
import boto3
import os
import datetime

def lambda_handler(event, context):
    rds = boto3.client('rds')
    
    cluster_id = os.environ['DB_CLUSTER_ID']
    s3_bucket = os.environ['S3_BUCKET_NAME']
    kms_key = os.environ['KMS_KEY_ARN']
    iam_role = os.environ['EXPORT_ROLE_ARN']
    s3_prefix = os.environ.get('S3_PREFIX', 'RDS_Backups/')
    
    response = rds.describe_db_cluster_snapshots(
        DBClusterIdentifier=cluster_id,
        SnapshotType='automated',
        IncludeShared=False,
        IncludePublic=False
    )
    
    snapshots = sorted(response['DBClusterSnapshots'], key=lambda x: x['SnapshotCreateTime'], reverse=True)
    if not snapshots:
        raise Exception("No automated snapshots found for cluster")
        
    latest_snapshot = snapshots[0]['DBClusterSnapshotArn']
    timestamp = datetime.datetime.now().strftime("%Y-%m-%d-%H-%M")
    export_task_id = f"moodle-export-{timestamp}"
    
    export_response = rds.start_export_task(
        ExportTaskIdentifier=export_task_id,
        SourceArn=latest_snapshot,
        S3BucketName=s3_bucket,
        IamRoleArn=iam_role,
        KmsKeyId=kms_key,
        S3Prefix=s3_prefix
    )
    
    return {
        'statusCode': 200,
        'body': f"Export task {export_task_id} started successfully."
    }
EOF

zip function.zip index.py > /dev/null 2>&1

echo "   -> Waiting 15 seconds for IAM Roles to propagate globally..." | tee -a $LOG_FILE
sleep 15


echo "5. Deploying Lambda Function (with 60s timeout)..." | tee -a $LOG_FILE
export EXPORT_ROLE_ARN=$(aws iam get-role --role-name rds-s3-export-role --query "Role.Arn" --output text)
export LAMBDA_ROLE_ARN=$(aws iam get-role --role-name rds-snapshot-exporter-lambda-role --query "Role.Arn" --output text)

aws lambda create-function   --function-name export-rds-snapshot-to-s3   --runtime python3.12   --role $LAMBDA_ROLE_ARN   --handler index.lambda_handler   --timeout 60   --zip-file fileb://function.zip   --environment "Variables={DB_CLUSTER_ID=$DB_CLUSTER_ID,S3_BUCKET_NAME=$S3_BUCKET_NAME,KMS_KEY_ARN=$KMS_KEY_ARN,EXPORT_ROLE_ARN=$EXPORT_ROLE_ARN,S3_PREFIX=$S3_PREFIX}"   --region $REGION >> $LOG_FILE 2>&1 || aws lambda update-function-code   --function-name export-rds-snapshot-to-s3   --zip-file fileb://function.zip   --region $REGION >> $LOG_FILE 2>&1

aws lambda update-function-configuration   --function-name export-rds-snapshot-to-s3   --timeout 60   --environment "Variables={DB_CLUSTER_ID=$DB_CLUSTER_ID,S3_BUCKET_NAME=$S3_BUCKET_NAME,KMS_KEY_ARN=$KMS_KEY_ARN,EXPORT_ROLE_ARN=$EXPORT_ROLE_ARN,S3_PREFIX=$S3_PREFIX}"   --region $REGION >> $LOG_FILE 2>&1


echo "6. Configuring EventBridge Trigger (Every Sunday at 14:35 UTC)..." | tee -a $LOG_FILE
aws events put-rule   --name sunday-rds-s3-export-schedule   --schedule-expression "cron(35 14 ? * SUN *)"   --state ENABLED   --region $REGION >> $LOG_FILE 2>&1

export RULE_ARN=$(aws events describe-rule --name sunday-rds-s3-export-schedule --region $REGION --query "Arn" --output text)
export LAMBDA_ARN=$(aws lambda get-function --function-name export-rds-snapshot-to-s3 --region $REGION --query 'Configuration.FunctionArn' --output text)

aws lambda add-permission   --function-name export-rds-snapshot-to-s3   --statement-id EventBridgeInvoke   --action lambda:InvokeFunction   --principal events.amazonaws.com   --source-arn $RULE_ARN   --region $REGION 2>>$LOG_FILE || echo "   -> EventBridge permission already exists." | tee -a $LOG_FILE

aws events put-targets   --rule sunday-rds-s3-export-schedule   --targets "Id"="1","Arn"="$LAMBDA_ARN"   --region $REGION >> $LOG_FILE 2>&1

echo "================================================================" | tee -a $LOG_FILE
echo "Setup Complete! Automated RDS to S3 export is fully configured." | tee -a $LOG_FILE
