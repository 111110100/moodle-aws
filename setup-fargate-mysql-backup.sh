#!/bin/bash
# Exit immediately if a command fails
set -eou pipefail

export LOG_FILE="setup_fargate_backup.log"
export REGION="ap-southeast-2"
export DB_CLUSTER_ID="maru-moodle-db"
export S3_BUCKET_NAME="maru-moodle-data-2026"
export KMS_ALIAS="alias/moodle-rds-s3-export-key"
export S3_PREFIX="MySQL_Dumps/"
export DB_NAME="moodle"
export DB_USERNAME="moodleadmin"
export MYSQL_PWD="Temp123()"

export CLUSTER_NAME="maru-moodle-backup-cluster"
export ECR_REPO_NAME="moodle-mysql-backup"
export TASK_FAMILY="moodle-fargate-backup-task"
export EVENT_RULE_NAME="sunday-fargate-mysql-backup"

> $LOG_FILE
echo "Starting Serverless Fargate MySQL Backup Provisioning..." | tee -a $LOG_FILE
echo "========================================================" | tee -a $LOG_FILE

export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export KMS_KEY_ARN=$(aws kms describe-key --key-id $KMS_ALIAS --region $REGION --query "KeyMetadata.Arn" --output text 2>>$LOG_FILE)
export DB_HOST=$(aws rds describe-db-clusters --db-cluster-identifier $DB_CLUSTER_ID --region $REGION --query "DBClusters[0].Endpoint" --output text 2>>$LOG_FILE)


echo "1. Creating ECR Repository..." | tee -a $LOG_FILE
aws ecr create-repository   --repository-name $ECR_REPO_NAME   --region $REGION >> $LOG_FILE 2>&1 || echo "   -> ECR Repository already exists." | tee -a $LOG_FILE

export REPO_URI="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com/${ECR_REPO_NAME}"


echo "2. Building and Pushing Docker Image..." | tee -a $LOG_FILE
cat << 'EOF' > container-backup.sh
#!/bin/bash
set -e
echo "Starting Combined Fargate Backup (MySQL + .mbz Course Files)..."

TIMESTAMP=$(date +"%Y-%m-%d-%H-%M")
DB_BACKUP_FILE="/tmp/moodle-db-${TIMESTAMP}.sql.gz"
CERT_FILE="/tmp/rds-ca-bundle.pem"

# 1. Database Backup
echo "Downloading AWS RDS CA certificate bundle..."
curl -sS https://truststore.pki.rds.amazonaws.com/ap-southeast-2/ap-southeast-2-bundle.pem -o "$CERT_FILE"

echo "Generating database dump via mariadb-dump..."
mariadb-dump -h "$DB_HOST" \
  -u "$DB_USERNAME" \
  --single-transaction \
  --routines \
  --triggers \
  --ssl \
  --ssl-ca="$CERT_FILE" \
  "$DB_NAME" | gzip > "$DB_BACKUP_FILE"

echo "Database dump complete. Uploading to S3..."
aws s3 cp "$DB_BACKUP_FILE" "s3://${S3_BUCKET_NAME}/MySQL_Dumps/moodle-db-${TIMESTAMP}.sql.gz" \
  --sse aws:kms \
  --sse-kms-key-id "$KMS_KEY_ARN" \
  --region "$REGION"

rm -f "$DB_BACKUP_FILE" "$CERT_FILE"
echo "MySQL backup successfully uploaded."

# 2. Moodle Course .mbz Backups Sync from EFS
LOCAL_MBZ_DIR="/mnt/moodledata/moodle_backups"

if [ -d "$LOCAL_MBZ_DIR" ]; then
    echo "Syncing Moodle .mbz files from EFS to S3..."
    aws s3 sync "$LOCAL_MBZ_DIR" "s3://${S3_BUCKET_NAME}/Backups/" \
      --exclude "*" \
      --include "*.mbz" \
      --sse aws:kms \
      --sse-kms-key-id "$KMS_KEY_ARN" \
      --region "$REGION"
    echo ".mbz backup sync complete successfully!"
else
    echo "WARNING: EFS mount path $LOCAL_MBZ_DIR not found. Skipping .mbz sync."
fi

echo "All backup routines completed successfully!"
EOF

cat << 'EOF' > Dockerfile
FROM alpine:latest
RUN apk add --no-cache mysql-client aws-cli bash curl ca-certificates
COPY container-backup.sh /backup.sh
RUN chmod +x /backup.sh
ENTRYPOINT ["/backup.sh"]
EOF

echo "   -> Authenticating Docker to ECR..." | tee -a $LOG_FILE
aws ecr get-login-password --region $REGION | docker login --username AWS --password-stdin $REPO_URI > /dev/null 2>&1
echo "   -> Building image..." | tee -a $LOG_FILE
docker build -t $ECR_REPO_NAME . > /dev/null 2>&1
docker tag ${ECR_REPO_NAME}:latest ${REPO_URI}:latest
echo "   -> Pushing image to ECR..." | tee -a $LOG_FILE
docker push ${REPO_URI}:latest > /dev/null 2>&1


echo "3. Setting up IAM Roles..." | tee -a $LOG_FILE

# 3.1 Task Execution Role (Allows Fargate to pull from ECR and push logs)
cat << 'EOF' > ecs-trust-policy.json
{
  "Version": "2012-10-17",
  "Statement": [{ "Effect": "Allow", "Principal": { "Service": "ecs-tasks.amazonaws.com" }, "Action": "sts:AssumeRole" }]
}
EOF

aws iam create-role --role-name ecsTaskExecutionRole --assume-role-policy-document file://ecs-trust-policy.json 2>>$LOG_FILE || true
aws iam attach-role-policy --role-name ecsTaskExecutionRole --policy-arn arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy 2>>$LOG_FILE || true

# 3.2 Task Role (Allows the Container to write to S3 and use KMS)
aws iam create-role --role-name fargate-mysql-backup-task-role --assume-role-policy-document file://ecs-trust-policy.json 2>>$LOG_FILE || true

cat << EOF > fargate-s3-kms-policy.json
{
  "Version": "2012-10-17",
  "Statement": [
    { "Effect": "Allow", "Action": ["s3:PutObject", "s3:GetObject", "s3:ListBucket"], "Resource": ["arn:aws:s3:::$S3_BUCKET_NAME", "arn:aws:s3:::$S3_BUCKET_NAME/*"] },
    { "Effect": "Allow", "Action": ["kms:Encrypt", "kms:Decrypt", "kms:GenerateDataKey*"], "Resource": "$KMS_KEY_ARN" },
    { "Effect": "Allow", "Action": ["elasticfilesystem:ClientMount", "elasticfilesystem:ClientRootAccess", "elasticfilesystem:DescribeFileSystems"], "Resource": "*" }
  ]
}
EOF
aws iam put-role-policy --role-name fargate-mysql-backup-task-role --policy-name FargateS3KMSEFSAccess --policy-document file://fargate-s3-kms-policy.json 2>>$LOG_FILE

# 3.3 EventBridge Trigger Role (Allows EventBridge to launch the ECS Task)
cat << 'EOF' > events-trust-policy.json
{
  "Version": "2012-10-17",
  "Statement": [{ "Effect": "Allow", "Principal": { "Service": "events.amazonaws.com" }, "Action": "sts:AssumeRole" }]
}
EOF
aws iam create-role --role-name events-ecs-invoke-role --assume-role-policy-document file://events-trust-policy.json 2>>$LOG_FILE || true

cat << 'EOF' > events-ecs-policy.json
{
  "Version": "2012-10-17",
  "Statement": [
    { "Effect": "Allow", "Action": "ecs:RunTask", "Resource": "*" },
    { "Effect": "Allow", "Action": "iam:PassRole", "Resource": "*" }
  ]
}
EOF
aws iam put-role-policy --role-name events-ecs-invoke-role --policy-name EventsECSTaskRunner --policy-document file://events-ecs-policy.json 2>>$LOG_FILE


echo "4. Creating ECS Cluster & CloudWatch Logs..." | tee -a $LOG_FILE
aws ecs create-cluster --cluster-name $CLUSTER_NAME --region $REGION >> $LOG_FILE 2>&1 || true
aws logs create-log-group --log-group-name /ecs/$TASK_FAMILY --region $REGION 2>>$LOG_FILE || true


echo "5. Registering ECS Task Definition..." | tee -a $LOG_FILE
export EXECUTION_ROLE_ARN=$(aws iam get-role --role-name ecsTaskExecutionRole --query "Role.Arn" --output text)
export TASK_ROLE_ARN=$(aws iam get-role --role-name fargate-mysql-backup-task-role --query "Role.Arn" --output text)

# Automatically fetch your Moodle EFS File System ID
EFS_FS_ID=$(aws efs describe-file-systems --region $REGION --query "FileSystems[0].FileSystemId" --output text)

cat << EOF > task-def.json
{
  "family": "moodle-fargate-backup-task",
  "networkMode": "awsvpc",
  "requiresCompatibilities": ["FARGATE"],
  "cpu": "256",
  "memory": "512",
  "executionRoleArn": "$EXECUTION_ROLE_ARN",
  "taskRoleArn": "$TASK_ROLE_ARN",
  "volumes": [
    {
      "name": "moodle-efs-volume",
      "efsVolumeConfiguration": {
        "fileSystemId": "$EFS_FS_ID",
        "rootDirectory": "/",
        "transitEncryption": "ENABLED"
      }
    }
  ],
  "containerDefinitions": [
    {
      "name": "backup-container",
      "image": "${REPO_URI}:latest",
      "essential": true,
      "environment": [
        {"name": "DB_HOST", "value": "$DB_HOST"},
        {"name": "DB_USERNAME", "value": "$DB_USERNAME"},
        {"name": "MYSQL_PWD", "value": "$MYSQL_PWD"},
        {"name": "DB_NAME", "value": "$DB_NAME"},
        {"name": "S3_BUCKET_NAME", "value": "$S3_BUCKET_NAME"},
        {"name": "KMS_KEY_ARN", "value": "$KMS_KEY_ARN"},
        {"name": "REGION", "value": "$REGION"}
      ],
      "mountPoints": [
        {
          "sourceVolume": "moodle-efs-volume",
          "containerPath": "/mnt/moodledata",
          "readOnly": true
        }
      ],
      "logConfiguration": {
        "logDriver": "awslogs",
        "options": {
          "awslogs-group": "/ecs/moodle-fargate-backup-task",
          "awslogs-region": "$REGION",
          "awslogs-stream-prefix": "ecs"
        }
      }
    }
  ]
}
EOF
aws ecs register-task-definition --cli-input-json file://task-def.json --region $REGION >> $LOG_FILE 2>&1


echo "6. Configuring EventBridge Trigger (Every Sunday at 1am UTC)..." | tee -a $LOG_FILE
# Dynamically fetch default networking so the Fargate task has internet access to reach ECR/S3
DEFAULT_VPC_ID=$(aws ec2 describe-vpcs --filters "Name=isDefault,Values=true" --region $REGION --query "Vpcs[0].VpcId" --output text)
SUBNET_ID=$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$DEFAULT_VPC_ID" --region $REGION --query "Subnets[0].SubnetId" --output text)
SG_ID=$(aws ec2 describe-security-groups --filters "Name=vpc-id,Values=$DEFAULT_VPC_ID" "Name=group-name,Values=default" --region $REGION --query "SecurityGroups[0].GroupId" --output text)

EVENTS_ROLE_ARN=$(aws iam get-role --role-name events-ecs-invoke-role --query "Role.Arn" --output text)
TASK_DEF_ARN=$(aws ecs describe-task-definition --task-definition $TASK_FAMILY --region $REGION --query "taskDefinition.taskDefinitionArn" --output text)

aws events put-rule   --name $EVENT_RULE_NAME   --schedule-expression "cron(0 1 ? * SUN *)"   --state ENABLED   --region $REGION >> $LOG_FILE 2>&1

cat << EOF > ecs-target.json
[
  {
    "Id": "1",
    "Arn": "arn:aws:ecs:${REGION}:${ACCOUNT_ID}:cluster/${CLUSTER_NAME}",
    "RoleArn": "${EVENTS_ROLE_ARN}",
    "EcsParameters": {
      "TaskDefinitionArn": "${TASK_DEF_ARN}",
      "TaskCount": 1,
      "LaunchType": "FARGATE",
      "NetworkConfiguration": {
        "awsvpcConfiguration": {
          "Subnets": ["${SUBNET_ID}"],
          "SecurityGroups": ["${SG_ID}"],
          "AssignPublicIp": "ENABLED"
        }
      }
    }
  }
]
EOF

aws events put-targets   --rule $EVENT_RULE_NAME   --targets file://ecs-target.json   --region $REGION >> $LOG_FILE 2>&1

echo "========================================================" | tee -a $LOG_FILE
echo "Setup Complete! Fargate will execute mysqldump automatically." | tee -a $LOG_FILE
