#!/bin/bash
# Exit immediately if a command fails, but allow specific expected duplicates (like IAM roles/rules) to bypass.
set -e 
set -o pipefail

LOG_FILE="moodle_aws_setup.log"
REGION="ap-southeast-2"
APP_NAME="MaruMoodleLMS"
ENV_NAME="MaruMoodle-Prod-v2"
DB_CLUSTER_ID="maru-moodle-db"
DB_INSTANCE_ID="maru-moodle-db-instance"
REDIS_ID="maru-moodle-redis"

> $LOG_FILE
echo "Starting Advanced AWS Infrastructure Provisioning for Moodle..." | tee -a $LOG_FILE
echo "=====================================================================" | tee -a $LOG_FILE

setup_iam() {
    echo "1. Configuring IAM Roles & Instance Profiles..." | tee -a $LOG_FILE
    
    # 1.1 Create EC2 Trust Policy
    cat << 'EOF' > ec2-trust-policy.json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": { "Service": "ec2.amazonaws.com" },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF
    
    # 1.2 Create EB EC2 Role & Attach Managed Policy
    aws iam create-role --role-name aws-elasticbeanstalk-ec2-role --assume-role-policy-document file://ec2-trust-policy.json 2>>$LOG_FILE || echo "   -> Role already exists." | tee -a $LOG_FILE
    aws iam attach-role-policy --role-name aws-elasticbeanstalk-ec2-role --policy-arn arn:aws:iam::aws:policy/AWSElasticBeanstalkWebTier 2>>$LOG_FILE || true
    
    # 1.3 Create Instance Profile and link Role
    aws iam create-instance-profile --instance-profile-name aws-elasticbeanstalk-ec2-role 2>>$LOG_FILE || echo "   -> Instance profile exists." | tee -a $LOG_FILE
    aws iam add-role-to-instance-profile --instance-profile-name aws-elasticbeanstalk-ec2-role --role-name aws-elasticbeanstalk-ec2-role 2>>$LOG_FILE || true

    # 1.4 Create GitHub Actions Deployment User & Output Keys
    aws iam create-user --user-name github-actions-moodle-deploy 2>>$LOG_FILE || echo "   -> GitHub Deploy User already exists." | tee -a $LOG_FILE
    aws iam attach-user-policy --user-name github-actions-moodle-deploy --policy-arn arn:aws:iam::aws:policy/AWSElasticBeanstalkAdministrator 2>>$LOG_FILE || true
    
    echo "   -> Generating Deployment Keys (Saved to github_deploy_keys.json)..." | tee -a $LOG_FILE
    aws iam create-access-key --user-name github-actions-moodle-deploy > github_deploy_keys.json || echo "   -> Key limit reached for user." | tee -a $LOG_FILE
}

provision_efs() {
    echo "2. Provisioning Elastic File System (EFS) & Subnet Mounts..." | tee -a $LOG_FILE
    EFS_ID=$(aws efs create-file-system --creation-token MoodleEFS --encrypted --region $REGION --query 'FileSystemId' --output text 2>>$LOG_FILE || aws efs describe-file-systems --query "FileSystems[?CreationToken=='MoodleEFS'].FileSystemId" --output text)
    echo "   -> EFS Created: $EFS_ID" | tee -a $LOG_FILE

    # Get Default VPC and Security Group
    DEFAULT_VPC_ID=$(aws ec2 describe-vpcs --filters "Name=isDefault,Values=true" --region $REGION --query "Vpcs[0].VpcId" --output text 2>>$LOG_FILE)
    DEFAULT_SG_ID=$(aws ec2 describe-security-groups --filters "Name=vpc-id,Values=$DEFAULT_VPC_ID" "Name=group-name,Values=default" --region $REGION --query "SecurityGroups[0].GroupId" --output text 2>>$LOG_FILE)
    
    # Create Mount Targets in all Default Subnets
    SUBNETS=$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$DEFAULT_VPC_ID" --region $REGION --query "Subnets[*].SubnetId" --output text 2>>$LOG_FILE)
    for subnet in $SUBNETS; do
        aws efs create-mount-target --file-system-id $EFS_ID --subnet-id $subnet --security-groups $DEFAULT_SG_ID 2>>$LOG_FILE || echo "   -> Mount target already exists for $subnet" | tee -a $LOG_FILE
    done
    export EFS_ID
}

provision_redis() {
    echo "3. Provisioning ElastiCache (Cluster Mode Enabled & Autoscaling)..." | tee -a $LOG_FILE
    # Upgraded from cache-cluster to replication-group for Multi-AZ and Autoscaling support
    aws elasticache create-replication-group \
        --replication-group-id $REDIS_ID \
        --replication-group-description "Moodle Redis Cluster" \
        --engine redis \
        --cache-node-type cache.t4g.micro \
        --num-cache-clusters 2 \
        --automatic-failover-enabled \
        --region $REGION >> $LOG_FILE 2>&1 || echo "   -> Redis Replication Group already exists." | tee -a $LOG_FILE
    
    # Register Redis for Autoscaling (Scale replicas based on CPU)
    aws application-autoscaling register-scalable-target \
        --service-namespace elasticache \
        --resource-id replication-group/$REDIS_ID \
        --scalable-dimension elasticache:replication-group:NodeGroups \
        --min-capacity 1 --max-capacity 3 >> $LOG_FILE 2>&1 || true
    echo "   -> Redis cluster and application autoscaling initiated." | tee -a $LOG_FILE
}

provision_aurora() {
    echo "4. Provisioning Aurora Serverless v2 (MySQL 8.4)..." | tee -a $LOG_FILE
    aws rds create-db-cluster --db-cluster-identifier $DB_CLUSTER_ID --engine aurora-mysql --engine-version 8.4.mysql_aurora.8.4.8 --master-username moodleadmin --master-user-password TempPassword123\! --serverless-v2-scaling-configuration MinCapacity=0.5,MaxCapacity=16.0 --region $REGION >> $LOG_FILE 2>&1 || echo "   -> Aurora Cluster exists." | tee -a $LOG_FILE
    aws rds create-db-instance --db-instance-identifier $DB_INSTANCE_ID --db-cluster-identifier $DB_CLUSTER_ID --engine aurora-mysql --db-instance-class db.serverless --region $REGION >> $LOG_FILE 2>&1 || echo "   -> Aurora Instance exists." | tee -a $LOG_FILE
}

provision_eb() {
    echo "5. Provisioning Elastic Beanstalk (CPU Autoscaling: 30%-70%)..." | tee -a $LOG_FILE
    aws elasticbeanstalk create-application --application-name $APP_NAME --region $REGION >> $LOG_FILE 2>&1 || true

    # Generate EB Autoscaling Options
    cat << 'EOF' > eb-options.json
[
  {"Namespace": "aws:autoscaling:launchconfiguration", "OptionName": "IamInstanceProfile", "Value": "aws-elasticbeanstalk-ec2-role"},
  {"Namespace": "aws:autoscaling:asg", "OptionName": "MinSize", "Value": "1"},
  {"Namespace": "aws:autoscaling:asg", "OptionName": "MaxSize", "Value": "4"},
  {"Namespace": "aws:autoscaling:trigger", "OptionName": "MeasureName", "Value": "CPUUtilization"},
  {"Namespace": "aws:autoscaling:trigger", "OptionName": "Unit", "Value": "Percent"},
  {"Namespace": "aws:autoscaling:trigger", "OptionName": "LowerThreshold", "Value": "30"},
  {"Namespace": "aws:autoscaling:trigger", "OptionName": "UpperThreshold", "Value": "70"}
]
EOF

    STACK_NAME=$(aws elasticbeanstalk list-available-solution-stacks --region $REGION --query "SolutionStacks[?contains(@, 'running PHP 8.3')] | [0]" --output text 2>>$LOG_FILE)
    aws elasticbeanstalk create-environment --application-name $APP_NAME --environment-name $ENV_NAME --solution-stack-name "$STACK_NAME" --option-settings file://eb-options.json --region $REGION >> $LOG_FILE 2>&1 || echo "   -> EB Environment already exists." | tee -a $LOG_FILE

    echo "   -> Waiting for EB Security Group to generate..." | tee -a $LOG_FILE
    while true; do
        EB_SG_ID=$(aws ec2 describe-security-groups --region $REGION --filters "Name=tag:elasticbeanstalk:environment-name,Values=$ENV_NAME" --query "SecurityGroups[0].GroupId" --output text 2>>$LOG_FILE || true)
        if [ "$EB_SG_ID" != "None" ] && [ -n "$EB_SG_ID" ]; then
            echo "   -> Found Elastic Beanstalk SG: $EB_SG_ID" | tee -a $LOG_FILE
            break
        fi
        sleep 10
    done
}

provision_s3() {
    echo "X. Provisioning Dedicated S3 Bucket..." | tee -a $LOG_FILE

    # Generate a globally unique bucket name
    ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
    S3_BUCKET_NAME="maru-moodle-storage-${ACCOUNT_ID}-${REGION}"

    # Create the bucket
    aws s3api create-bucket \
        --bucket $S3_BUCKET_NAME \
        --region $REGION \
        --create-bucket-configuration LocationConstraint=$REGION >> $LOG_FILE 2>&1 || echo "   -> Bucket exists." | tee -a $LOG_FILE

    # Enforce strict private access
    aws s3api put-public-access-block \
        --bucket $S3_BUCKET_NAME \
        --public-access-block-configuration "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true" >> $LOG_FILE 2>&1

    echo "   -> S3 Bucket Created: $S3_BUCKET_NAME" | tee -a $LOG_FILE

    # Grant Elastic Beanstalk EC2 instances access to this specific bucket
    cat << EOF > s3-access-policy.json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["s3:ListBucket"],
      "Resource": ["arn:aws:s3:::$S3_BUCKET_NAME"]
    },
    {
      "Effect": "Allow",
      "Action": ["s3:PutObject", "s3:GetObject", "s3:DeleteObject"],
      "Resource": ["arn:aws:s3:::$S3_BUCKET_NAME/*"]
    }
  ]
}
EOF
    aws iam put-role-policy --role-name aws-elasticbeanstalk-ec2-role --policy-name MoodleS3AccessPolicy --policy-document file://s3-access-policy.json 2>>$LOG_FILE || true
    echo "   -> Attached IAM access policy to EC2 instance profile." | tee -a $LOG_FILE
}

apply_security() {
    echo "6. Applying Network Security Group Bindings..." | tee -a $LOG_FILE
    EB_SG_ID=$(aws ec2 describe-security-groups --region $REGION --filters "Name=tag:elasticbeanstalk:environment-name,Values=$ENV_NAME" --query "SecurityGroups[0].GroupId" --output text 2>>$LOG_FILE)
    DEFAULT_VPC_ID=$(aws ec2 describe-security-groups --group-ids $EB_SG_ID --region $REGION --query "SecurityGroups[0].VpcId" --output text 2>>$LOG_FILE)
    DEFAULT_SG_ID=$(aws ec2 describe-security-groups --filters "Name=vpc-id,Values=$DEFAULT_VPC_ID" "Name=group-name,Values=default" --region $REGION --query "SecurityGroups[0].GroupId" --output text 2>>$LOG_FILE)

    aws ec2 authorize-security-group-egress --group-id $EB_SG_ID --protocol -1 --cidr 0.0.0.0/0 --region $REGION 2>>$LOG_FILE || true
    aws ec2 authorize-security-group-ingress --region $REGION --group-id $DEFAULT_SG_ID --protocol tcp --port 3306 --source-group $EB_SG_ID 2>>$LOG_FILE || true
    aws ec2 authorize-security-group-ingress --region $REGION --group-id $DEFAULT_SG_ID --protocol tcp --port 6379 --source-group $EB_SG_ID 2>>$LOG_FILE || true
    aws ec2 authorize-security-group-ingress --region $REGION --group-id $DEFAULT_SG_ID --protocol tcp --port 2049 --source-group $EB_SG_ID 2>>$LOG_FILE || true

    aws rds modify-db-cluster --db-cluster-identifier $DB_CLUSTER_ID --vpc-security-group-ids $EB_SG_ID $DEFAULT_SG_ID --apply-immediately --region $REGION >> $LOG_FILE 2>&1
    aws elasticache modify-replication-group --replication-group-id $REDIS_ID --security-group-ids $EB_SG_ID $DEFAULT_SG_ID --apply-immediately --region $REGION >> $LOG_FILE 2>&1
}

generate_codebase() {
    echo "7. Generating Repository Configuration Files..." | tee -a $LOG_FILE
    
    # 7.1 .ebextensions
    mkdir -p .ebextensions
    cat << EOF > .ebextensions/01-efs-mount.config
packages:
  yum:
    amazon-efs-utils: []
commands:
  01_mount_efs:
    command: |
      mkdir -p /mnt/moodledata
      mount -t efs -o tls ${EFS_ID}:/ /mnt/moodledata
      chown -R webapp:webapp /mnt/moodledata
      chmod 777 /mnt/moodledata
EOF

    cat << 'EOF' > .ebextensions/02-php-settings.config
files:
  "/etc/php.d/99-moodle.ini":
    mode: "000644"
    owner: root
    group: root
    content: |
      display_errors = On
      upload_max_filesize = 128M
      post_max_size = 128M
      max_execution_time = 300
      memory_limit = 512M
      opcache.enable = 1
EOF

    # 7.2 GitHub Actions
    mkdir -p .github/workflows
    cat << 'EOF' > .github/workflows/deploy.yml
name: Deploy Moodle to AWS Elastic Beanstalk
on:
  push:
    branches: [ "main" ]
jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
    - uses: actions/checkout@v3
    - name: Deploy to EB
      uses: einaregilsson/beanstalk-deploy@v22
      with:
        aws_access_key: ${{ secrets.AWS_ACCESS_KEY_ID }}
        aws_secret_key: ${{ secrets.AWS_SECRET_ACCESS_KEY }}
        application_name: MaruMoodleLMS
        environment_name: MaruMoodle-Prod-v2
        version_label: ${{ github.sha }}
        region: ap-southeast-2
        deployment_package: HEAD
EOF

    # 7.3 Diagnostic PHP Script
    cat << 'EOF' > sys-test.php
<?php
ini_set('display_errors', 1);
error_reporting(E_ALL);

echo "<h3>1. Testing Redis Connection</h3>";
$redis_endpoint = "maru-moodle-redis.XXXXXX.ng.0001.apse2.cache.amazonaws.com"; // Replace XXXXXX with actual primary endpoint

if (class_exists('Redis')) {
    $redis = new Redis();
    if (@$redis->connect($redis_endpoint, 6379, 5)) {
        echo "<strong style='color:green;'>Connected to Redis!</strong><br>";
    } else {
        echo "<strong style='color:red;'>Failed to connect to Redis.</strong><br>";
    }
} else { echo "<strong style='color:red;'>Redis extension missing.</strong><br>"; }

echo "<h3>2. Testing Aurora MySQL (SSL)</h3>";
$ip = gethostbyname("maru-moodle-db.cluster-crkc8w28olh1.ap-southeast-2.rds.amazonaws.com");
$mysqli = mysqli_init();
$mysqli->options(MYSQLI_OPT_CONNECT_TIMEOUT, 5);
if (@$mysqli->real_connect($ip, "moodleadmin", "TempPassword123!", "moodle", 3306, null, MYSQLI_CLIENT_SSL)) {
    echo "<strong style='color:green;'>Connected to Aurora MySQL!</strong><br>";
} else { echo "<strong style='color:red;'>MySQL Connection Failed: </strong>" . mysqli_connect_error() . "<br>"; }

echo "<h3>3. Testing EFS Mount</h3>";
$efs_path = '/mnt/moodledata';
if (is_dir($efs_path) && is_writable($efs_path)) {
    echo "<strong style='color:green;'>EFS Mount is writable!</strong><br>";
} else { echo "<strong style='color:red;'>EFS is not writable or missing.</strong><br>"; }
?>
EOF
    echo "   -> Codebase generated locally in CloudShell." | tee -a $LOG_FILE
}

# ======================================================================
# EXECUTION MODULES
# Comment out any of the functions below with a '#' to skip that step.
# ======================================================================
setup_iam
provision_s3
provision_efs
provision_redis
provision_aurora
provision_eb
apply_security
generate_codebase

echo "=====================================================================" | tee -a $LOG_FILE
echo "Setup Complete! Check github_deploy_keys.json for your Action Secrets." | tee -a $LOG_FILE
