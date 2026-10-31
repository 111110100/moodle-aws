#!/bin/bash
# Exit immediately if a command fails, but allow specific expected duplicates (like IAM roles/rules) to bypass.
set -eou pipefail

export LOG_FILE="moodle_aws_setup.log"
export REGION="ap-southeast-2"
export APP_NAME="MaruMoodleLMS"
export ENV_NAME="MaruMoodle-Prod"
export BUCKET_NAME="maru-moodle-storage"
export DB_CLUSTER_ID="maru-moodle-db"
export DB_INSTANCE_ID="maru-moodle-db-instance"
export DB_PARAM_GROUP="moodle-aurora-mysql84-params"
export DB_USERNAME="moodleadmin"
export DB_PASSWORD="Temp123()"
export REDIS_ID="maru-moodle-redis"
export WWWROOT="http://changeme.com"
export DOMAIN_NAME="changeme.com" # ADDED: Target domain for ACM Certificate provisioning
export SSL_COUNTRY="AU"
export SSL_STATE="New South Whales"
export SSL_LOCALITY="Sydney"
export SSL_ORG="CompanyName"
export SSL_UNIT="TECH"
export AWS_PAGER=""

> $LOG_FILE
echo "Starting Advanced AWS Infrastructure Provisioning for Moodle..." | tee -a $LOG_FILE
echo "=====================================================================" | tee -a $LOG_FILE

setup_iam() {
    echo "1. Configuring IAM Roles & Instance Profiles..." | tee -a $LOG_FILE

    # 1.1 Create EC2 Trust Policy
    cat << EOF > ec2-trust-policy.json
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

    # 1.2 Create EB EC2 Role & Attach Managed Policies (Including SSM Default Policy for Session Manager)
    aws iam create-role \
        --role-name aws-elasticbeanstalk-ec2-role \
        --assume-role-policy-document file://ec2-trust-policy.json 2>>$LOG_FILE || echo "   -> Role already exists." | tee -a $LOG_FILE
    aws iam attach-role-policy \
        --role-name aws-elasticbeanstalk-ec2-role \
        --policy-arn arn:aws:iam::aws:policy/AWSElasticBeanstalkWebTier 2>>$LOG_FILE || true
    aws iam attach-role-policy \
        --role-name aws-elasticbeanstalk-ec2-role \
        --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedEC2InstanceDefaultPolicy 2>>$LOG_FILE || true
    # ADDED: EFS Mount Target visibility policy
    aws iam attach-role-policy \
        --role-name aws-elasticbeanstalk-ec2-role \
        --policy-arn arn:aws:iam::aws:policy/AmazonElasticFileSystemClientReadWriteAccess 2>>$LOG_FILE || true

    # 1.3 Create Instance Profile and link Role
    aws iam create-instance-profile \
        --instance-profile-name aws-elasticbeanstalk-ec2-role 2>>$LOG_FILE || echo "   -> Instance profile exists." | tee -a $LOG_FILE
    aws iam add-role-to-instance-profile \
        --instance-profile-name aws-elasticbeanstalk-ec2-role \
        --role-name aws-elasticbeanstalk-ec2-role 2>>$LOG_FILE || true

    # 1.4 Create GitHub Actions Deployment User with LEAST PRIVILEGE
    aws iam create-user \
        --user-name github-actions-moodle-deploy 2>>$LOG_FILE || echo "   -> GitHub Deploy User already exists." | tee -a $LOG_FILE

    echo "   -> Generating Deployment Keys (Saved to github_deploy_keys.json)..." | tee -a $LOG_FILE
    aws iam create-access-key \
        --user-name github-actions-moodle-deploy > github_deploy_keys.json || echo "   -> Key limit reached for user." | tee -a $LOG_FILE

    # Scoped inline policy restricting the user strictly to EB deployment commands
    cat << EOF > eb-deploy-policy.json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "elasticbeanstalk:CreateApplicationVersion",
        "elasticbeanstalk:UpdateEnvironment",
        "elasticbeanstalk:DescribeEnvironments",
        "elasticbeanstalk:DescribeEvents",
        "elasticbeanstalk:DescribeApplicationVersions",
        "s3:PutObject",
        "s3:GetObject",
        "s3:GetObjectAcl",
        "s3:PutObjectAcl",
        "s3:ListBucket",
        "s3:DeleteObject",
        "s3:GetBucketPolicy"
      ],
      "Resource": [
        "arn:aws:elasticbeanstalk:$REGION:*:application/$APP_NAME",
        "arn:aws:elasticbeanstalk:$REGION:*:environment/$APP_NAME/*",
        "arn:aws:elasticbeanstalk:$REGION:*:applicationversion/$APP_NAME/*",
        "arn:aws:s3:::elasticbeanstalk-$REGION-*",
        "arn:aws:s3:::elasticbeanstalk-$REGION-*/*"
      ]
    },
    {
      "Effect": "Allow",
      "Action": "elasticbeanstalk:CheckDNSAvailability",
      "Resource": "*"
    }
  ]
}
EOF

    aws iam put-user-policy \
        --user-name github-actions-moodle-deploy \
        --policy-name EBDeployPolicy \
        --policy-document file://eb-deploy-policy.json 2>>$LOG_FILE || true

    # 1.5 Create Custom Service Role for Managed Updates
    cat << EOF > eb-service-trust-policy.json
{
    "Version": "2012-10-17",
    "Statement": [
        {
          "Effect": "Allow",
          "Principal": { "Service": "elasticbeanstalk.amazonaws.com" },
          "Action": "sts:AssumeRole"
        }
    ]
}
EOF

    aws iam create-role \
        --role-name aws-elasticbeanstalk-custom-service-role \
        --assume-role-policy-document file://eb-service-trust-policy.json 2>>$LOG_FILE || echo "    -> Custom Service Role already exists." | tee -a $LOG_FILE
    aws iam attach-role-policy \
        --role-name aws-elasticbeanstalk-custom-service-role \
        --policy-arn arn:aws:iam::aws:policy/service-role/AWSElasticBeanstalkService 2>>$LOG_FILE || true
    aws iam attach-role-policy \
        --role-name aws-elasticbeanstalk-custom-service-role \
        --policy-arn arn:aws:iam::aws:policy/service-role/AWSElasticBeanstalkEnhancedHealth 2>>$LOG_FILE || true
    aws iam attach-role-policy \
        --role-name aws-elasticbeanstalk-custom-service-role \
        --policy-arn arn:aws:iam::aws:policy/AWSElasticBeanstalkManagedUpdatesCustomerRolePolicy 2>>$LOG_FILE || true
}

provision_s3() {
    echo "2. Provisioning Dedicated S3 Bucket..." | tee -a $LOG_FILE

    # Generate a globally unique bucket name
    ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
    S3_BUCKET_NAME="${BUCKET_NAME}-${ACCOUNT_ID}-${REGION}"

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
    aws iam put-role-policy \
        --role-name aws-elasticbeanstalk-ec2-role \
        --policy-name MoodleS3AccessPolicy \
        --policy-document file://s3-access-policy.json 2>>$LOG_FILE || true
    echo "   -> Attached IAM access policy to EC2 instance profile." | tee -a $LOG_FILE
}

provision_efs() {
    echo "3. Provisioning Elastic File System (EFS) & Subnet Mounts..." | tee -a $LOG_FILE
    EFS_ID=$(aws efs create-file-system \
        --creation-token MoodleEFS \
        --encrypted \
        --region $REGION \
        --query 'FileSystemId' \
        --output text 2>>$LOG_FILE || aws efs describe-file-systems --query "FileSystems[?CreationToken=='MoodleEFS'].FileSystemId" --output text)
    echo "   -> EFS Created: $EFS_ID" | tee -a $LOG_FILE

    # Get Default VPC and Security Group
    DEFAULT_VPC_ID=$(aws ec2 describe-vpcs \
        --filters "Name=isDefault,Values=true" \
        --region $REGION \
        --query "Vpcs[0].VpcId" \
        --output text 2>>$LOG_FILE)
    DEFAULT_SG_ID=$(aws ec2 describe-security-groups \
        --filters "Name=vpc-id,Values=$DEFAULT_VPC_ID" "Name=group-name,Values=default" \
        --region $REGION \
        --query "SecurityGroups[0].GroupId" \
        --output text 2>>$LOG_FILE)

    # ADDED: Ensure VPC DNS attributes are active for EFS DNS resolution
    aws ec2 modify-vpc-attribute \
        --vpc-id $DEFAULT_VPC_ID \
        --enable-dns-support '{"Value":true}' 2>>$LOG_FILE || true
    aws ec2 modify-vpc-attribute \
        --vpc-id $DEFAULT_VPC_ID \
        --enable-dns-hostnames '{"Value":true}' 2>>$LOG_FILE || true

    # ADDED: Allow VPC CIDR ingress on port 2049 to prevent EB boot timeouts
    export VPC_CIDR=$(aws ec2 describe-vpcs \
        --vpc-ids $DEFAULT_VPC_ID \
        --query "Vpcs[0].CidrBlock" \
        --output text 2>>$LOG_FILE)
    aws ec2 authorize-security-group-ingress \
        --region $REGION \
        --group-id $DEFAULT_SG_ID \
        --protocol tcp \
        --port 2049 \
        --cidr $VPC_CIDR 2>>$LOG_FILE || true

    # Create Mount Targets in all Default Subnets
    SUBNETS=$(aws ec2 describe-subnets \
        --filters "Name=vpc-id,Values=$DEFAULT_VPC_ID" \
        --region $REGION \
        --query "Subnets[*].SubnetId" \
        --output text 2>>$LOG_FILE)
    for subnet in $SUBNETS; do
        aws efs create-mount-target \
            --file-system-id $EFS_ID \
            --subnet-id $subnet \
            --security-groups $DEFAULT_SG_ID 2>>$LOG_FILE || echo "   -> Mount target already exists for $subnet" | tee -a $LOG_FILE
    done
    export EFS_ID
}

provision_redis() {
    echo "4. Provisioning ElastiCache (Cluster Mode Enabled & Autoscaling & Transit Encryption)..." | tee -a $LOG_FILE
    aws elasticache create-replication-group \
        --replication-group-id $REDIS_ID \
        --replication-group-description "Moodle Redis Cluster" \
        --engine redis \
        --cache-node-type cache.t4g.micro \
        --num-cache-clusters 2 \
        --automatic-failover-enabled \
        --transit-encryption-enabled \
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
    echo "5. Provisioning Aurora Serverless v2 (MySQL 8.4)..." | tee -a $LOG_FILE

    aws rds create-db-cluster-parameter-group \
        --db-cluster-parameter-group-name $DB_PARAM_GROUP \
        --db-parameter-group-family aurora-mysql8.4 \
        --description "Moodle overrides for MySQL 8.4" \
        --region $REGION >> $LOG_FILE 2>&1 || echo "   -> Parameter group exists." | tee -a $LOG_FILE

    aws rds modify-db-cluster-parameter-group \
        --db-cluster-parameter-group-name $DB_PARAM_GROUP \
        --parameters "ParameterName=restrict_fk_on_non_standard_key,ParameterValue=OFF,ApplyMethod=immediate" \
        --region $REGION >> $LOG_FILE 2>&1 || true

    aws rds modify-db-cluster-parameter-group \
        --db-cluster-parameter-group-name $DB_PARAM_GROUP \
        --parameters "ParameterName=require_secure_transport,ParameterValue=OFF,ApplyMethod=immediate" \
        --region $REGION >> $LOG_FILE 2>&1 || true

    aws rds create-db-cluster \
        --db-cluster-identifier $DB_CLUSTER_ID \
        --engine aurora-mysql \
        --engine-version 8.4.mysql_aurora.8.4.8 \
        --master-username $DB_USERNAME \
        --master-user-password $DB_PASSWORD \
        --db-cluster-parameter-group-name $DB_PARAM_GROUP \
        --serverless-v2-scaling-configuration MinCapacity=0.5,MaxCapacity=16.0 \
        --preferred-backup-window "14:00-14:30" \
        --backup-retention-period 7 \
        --preferred-maintenance-window "Sat:15:00-Sat:15:30" \
        --region $REGION >> $LOG_FILE 2>&1 || echo "   -> Aurora Cluster exists." | tee -a $LOG_FILE

    aws rds create-db-instance \
        --db-instance-identifier $DB_INSTANCE_ID \
        --db-cluster-identifier $DB_CLUSTER_ID \
        --engine aurora-mysql \
        --db-instance-class db.serverless \
        --region $REGION >> $LOG_FILE 2>&1 || echo "   -> Aurora Instance exists." | tee -a $LOG_FILE
}

provision_acm_and_https() {
    echo "5.5 Requesting ACM SSL Certificate & Configuring HTTPS Listener..." | tee -a $LOG_FILE

    # Search for an existing certificate matching DOMAIN_NAME
    CERT_ARN=$(aws acm list-certificates \
        --region $REGION \
        --query "CertificateSummaryList[?DomainName=='$DOMAIN_NAME'].CertificateArn | [0]" \
        --output text 2>>$LOG_FILE || true)

    if [ "$CERT_ARN" == "None" ] || [ -z "$CERT_ARN" ]; then
        echo "   -> Requesting new public ACM certificate for $DOMAIN_NAME..." | tee -a $LOG_FILE
        CERT_ARN=$(aws acm request-certificate \
            --domain-name $DOMAIN_NAME \
            --validation-method DNS \
            --region $REGION \
            --query "CertificateArn" --output text 2>>$LOG_FILE)
        echo "   -> Requested ACM Certificate ARN: $CERT_ARN" | tee -a $LOG_FILE
        echo "   -> NOTE: Complete the DNS CNAME validation record in Cloudflare or your DNS manager for issuance." | tee -a $LOG_FILE
    else
        echo "   -> Existing ACM Certificate found: $CERT_ARN" | tee -a $LOG_FILE
    fi

    export CERT_ARN
}

provision_eb() {
    echo "6. Provisioning Elastic Beanstalk (CPU Autoscaling: 30%-70% & HTTPS Listener)..." | tee -a $LOG_FILE
    aws elasticbeanstalk create-application \
        --application-name $APP_NAME \
        --region $REGION >> $LOG_FILE 2>&1 || true

    # Ensure CERT_ARN is populated even if provision_acm_and_https was skipped
    if [ -z "$CERT_ARN" ] || [ "$CERT_ARN" == "None" ]; then
        CERT_ARN=$(aws acm list-certificates \
            --region $REGION \
            --query "CertificateSummaryList[?DomainName=='$DOMAIN_NAME'].CertificateArn | [0]" \
            --output text 2>>$LOG_FILE || true)
        if [ "$CERT_ARN" == "None" ] || [ -z "$CERT_ARN" ]; then
            provision_acm_and_https
        fi
    fi

    # Generate EB Autoscaling Options & Load Balancer Listener Rules
    cat << EOF > eb-options.json
[
{"Namespace": "aws:elasticbeanstalk:environment", "OptionName": "LoadBalancerType", "Value": "application"},
{"Namespace": "aws:elasticbeanstalk:environment", "OptionName": "ServiceRole", "Value": "aws-elasticbeanstalk-custom-service-role"},

{"Namespace": "aws:autoscaling:launchconfiguration", "OptionName": "IamInstanceProfile", "Value": "aws-elasticbeanstalk-ec2-role"},
{"Namespace": "aws:ec2:instances", "OptionName": "InstanceTypes", "Value": "t4g.medium, c7g.large"},

{"Namespace": "aws:autoscaling:asg", "OptionName": "MinSize", "Value": "1"},
{"Namespace": "aws:autoscaling:asg", "OptionName": "MaxSize", "Value": "10"},
{"Namespace": "aws:autoscaling:trigger", "OptionName": "MeasureName", "Value": "CPUUtilization"},
{"Namespace": "aws:autoscaling:trigger", "OptionName": "Unit", "Value": "Percent"},
{"Namespace": "aws:autoscaling:trigger", "OptionName": "LowerThreshold", "Value": "30"},
{"Namespace": "aws:autoscaling:trigger", "OptionName": "UpperThreshold", "Value": "70"},

{"Namespace": "aws:elbv2:listener:default", "OptionName": "ListenerEnabled", "Value": "true"},
{"Namespace": "aws:elbv2:listener:443", "OptionName": "ListenerEnabled", "Value": "true"},
{"Namespace": "aws:elbv2:listener:443", "OptionName": "Protocol", "Value": "HTTPS"},
{"Namespace": "aws:elbv2:listener:443", "OptionName": "SSLCertificateArns", "Value": "$CERT_ARN"},

{"Namespace": "aws:elasticbeanstalk:environment:process:default", "OptionName": "Port", "Value": "443"},
{"Namespace": "aws:elasticbeanstalk:environment:process:default", "OptionName": "Protocol", "Value": "HTTPS"},

{"Namespace": "aws:elasticbeanstalk:managedactions", "OptionName": "ManagedActionsEnabled", "Value": "true"},
{"Namespace": "aws:elasticbeanstalk:managedactions", "OptionName": "PreferredStartTime", "Value": "Sat:16:00"},
{"Namespace": "aws:elasticbeanstalk:managedactions:platformupdate", "OptionName": "UpdateLevel", "Value": "minor"},
{"Namespace": "aws:elasticbeanstalk:managedactions:platformupdate", "OptionName": "InstanceRefreshEnabled", "Value": "true"},

{"Namespace": "aws:elasticbeanstalk:command", "OptionName": "DeploymentPolicy", "Value": "Rolling" },
{"Namespace": "aws:autoscaling:updatepolicy:rollingupdate", "OptionName": "RollingUpdateEnabled", "Value": "true" },
{"Namespace": "aws:autoscaling:updatepolicy:rollingupdate", "OptionName": "RollingUpdateType", "Value": "Health" },
{"Namespace": "aws:autoscaling:updatepolicy:rollingupdate", "OptionName": "MinInstancesInService", "Value": "1" },
{"Namespace": "aws:autoscaling:updatepolicy:rollingupdate", "OptionName": "MaxBatchSize", "Value": "1" }
]
EOF

    STACK_NAME=$(aws elasticbeanstalk list-available-solution-stacks \
        --region $REGION \
        --query "SolutionStacks[?contains(@, 'running PHP 8.3')] | [0]" \
        --output text 2>>$LOG_FILE)
    aws elasticbeanstalk create-environment \
        --application-name $APP_NAME \
        --environment-name $ENV_NAME \
        --solution-stack-name "$STACK_NAME" \
        --option-settings file://eb-options.json \
        --region $REGION >> $LOG_FILE 2>&1 || echo "   -> EB Environment already exists." | tee -a $LOG_FILE

    echo "   -> Waiting for EB Security Group to generate..." | tee -a $LOG_FILE
    while true; do
        EB_SG_ID=$(aws ec2 describe-security-groups \
            --region $REGION \
            --filters "Name=tag:elasticbeanstalk:environment-name,Values=$ENV_NAME" \
            --query "SecurityGroups[0].GroupId" \
            --output text 2>>$LOG_FILE || true)
        if [ "$EB_SG_ID" != "None" ] && [ -n "$EB_SG_ID" ]; then
            echo "   -> Found Elastic Beanstalk SG: $EB_SG_ID" | tee -a $LOG_FILE
            break
        fi
        sleep 10
    done
}

apply_security() {
    echo "7. Applying Network Security Group Bindings..." | tee -a $LOG_FILE
    EB_SG_ID=$(aws ec2 describe-security-groups \
        --region $REGION \
        --filters "Name=tag:elasticbeanstalk:environment-name,Values=$ENV_NAME" \
        --query "SecurityGroups[0].GroupId" \
        --output text 2>>$LOG_FILE)
    DEFAULT_VPC_ID=$(aws ec2 describe-security-groups \
        --group-ids $EB_SG_ID \
        --region $REGION \
        --query "SecurityGroups[0].VpcId" \
        --output text 2>>$LOG_FILE)
    DEFAULT_SG_ID=$(aws ec2 describe-security-groups \
        --filters "Name=vpc-id,Values=$DEFAULT_VPC_ID" "Name=group-name,Values=default" \
        --region $REGION \
        --query "SecurityGroups[0].GroupId" \
        --output text 2>>$LOG_FILE)

    # ADDED: Authorize HTTPS inbound traffic on the Elastic Beanstalk Security Group
    aws ec2 authorize-security-group-ingress \
        --group-id $EB_SG_ID \
        --protocol tcp \
        --port 443 \
        --cidr 0.0.0.0/0 \
        --region $REGION 2>>$LOG_FILE || true

    aws ec2 authorize-security-group-egress \
        --group-id $EB_SG_ID \
        --protocol \
        -1 \
        --cidr 0.0.0.0/0 \
        --region $REGION 2>>$LOG_FILE || true
    aws ec2 authorize-security-group-ingress \
        --region $REGION \
        --group-id $DEFAULT_SG_ID \
        --protocol tcp \
        --port 3306 \
        --source-group $EB_SG_ID 2>>$LOG_FILE || true
    aws ec2 authorize-security-group-ingress \
        --region $REGION \
        --group-id $DEFAULT_SG_ID \
        --protocol tcp \
        --port 6379 \
        --source-group $EB_SG_ID 2>>$LOG_FILE || true
    aws ec2 authorize-security-group-ingress \
        --region $REGION \
        --group-id $DEFAULT_SG_ID \
        --protocol tcp \
        --port 2049 \
        --source-group $EB_SG_ID 2>>$LOG_FILE || true

    aws rds modify-db-cluster \
        --db-cluster-identifier $DB_CLUSTER_ID \
        --vpc-security-group-ids $EB_SG_ID $DEFAULT_SG_ID \
        --apply-immediately \
        --region $REGION >> $LOG_FILE 2>&1
    aws elasticache modify-replication-group \
        --replication-group-id $REDIS_ID \
        --security-group-ids $EB_SG_ID $DEFAULT_SG_ID \
        --apply-immediately \
        --region $REGION >> $LOG_FILE 2>&1
}


provision_ses() {
    echo "5.6 Provisioning AWS SES SMTP Credentials..." | tee -a $LOG_FILE

    # 1. Verify Domain Identity (Requires manual confirmation via email link)
    aws ses verify-email-identity \
        --email-address "no-reply@${DOMAIN_NAME}" \
        --region $REGION >> $LOG_FILE 2>&1 || echo "   -> Identity already verified or pending." | tee -a $LOG_FILE
    echo "   -> NOTE: Verification email sent to no-reply@${DOMAIN_NAME}. Check your inbox." | tee -a $LOG_FILE

    # 2. Create IAM User and Policy
    aws iam create-user --user-name moodle-ses-smtp-user 2>>$LOG_FILE || echo "   -> SES IAM User exists." | tee -a $LOG_FILE
    aws iam attach-user-policy \
        --user-name moodle-ses-smtp-user \
        --policy-arn arn:aws:iam::aws:policy/AmazonSesSendingAccess 2>>$LOG_FILE || true

    # 3. Generate New Access Keys
    echo "   -> Generating SES SMTP Keys..." | tee -a $LOG_FILE
    CREDENTIALS=$(aws iam create-access-key --user-name moodle-ses-smtp-user --query 'AccessKey.[AccessKeyId,SecretAccessKey]' --output text 2>>$LOG_FILE || true)

    if [ -n "$CREDENTIALS" ]; then
        ACCESS_KEY=$(echo "$CREDENTIALS" | awk '{print $1}')
        SECRET_KEY=$(echo "$CREDENTIALS" | awk '{print $2}')

        # 4. Derive SMTP Password natively via Python
        SMTP_PASSWORD=$(python3 -c "
import hmac, hashlib, base64
def sign(key, msg): return hmac.new(key, msg.encode('utf-8'), hashlib.sha256).digest()
signature = sign(('AWS4' + '$SECRET_KEY').encode('utf-8'), '11111111')
signature = sign(signature, '$REGION')
signature = sign(signature, 'ses')
signature = sign(signature, 'aws4_request')
signature = sign(signature, 'SendRawEmail')
print(base64.b64encode(bytes([0x04]) + signature).decode('utf-8'))
")

        # 5. Output safe credentials file
        cat << EOF > ses_smtp_credentials.txt
SES SMTP Configuration for Moodle
=================================
SMTP hosts: email-smtp.${REGION}.amazonaws.com:465
SMTP security: SSL
SMTP Auth Type: LOGIN
SMTP username: ${ACCESS_KEY}
SMTP password: ${SMTP_PASSWORD}
No-reply address: no-reply@${DOMAIN_NAME}
EOF
        echo "   -> SES Credentials successfully derived and saved to ses_smtp_credentials.txt" | tee -a $LOG_FILE
    else
        echo "   -> WARNING: Could not generate SES keys. User may have reached the 2-key IAM limit." | tee -a $LOG_FILE
    fi
}

generate_codebase() {
    echo "8. Generating Repository Configuration Files..." | tee -a $LOG_FILE

    # Dynamic Fallback: Resolve VPC_CIDR if provision_efs was skipped or unexported
    if [ -z "$VPC_CIDR" ]; then
        DEFAULT_VPC_ID=$(aws ec2 describe-vpcs --filters "Name=isDefault,Values=true" --region $REGION --query "Vpcs[0].VpcId" --output text 2>/dev/null || true)
        export VPC_CIDR=$(aws ec2 describe-vpcs --vpc-ids $DEFAULT_VPC_ID --region $REGION --query "Vpcs[0].CidrBlock" --output text 2>/dev/null || echo "172.31.0.0/16")
    else
        export VPC_CIDR
    fi

    # Dynamic Fallback: Resolve EFS_ID if provision_efs was skipped
    if [ -z "$EFS_ID" ]; then
        export EFS_ID=$(aws efs describe-file-systems --region $REGION --query "FileSystems[?CreationToken=='MoodleEFS'].FileSystemId | [0]" --output text 2>/dev/null || echo "fs-placeholder")
    fi

    # Fetch dynamic endpoints from AWS
    echo "   -> Retrieving Aurora and Redis endpoints..." | tee -a $LOG_FILE
    export DB_HOST=$(aws rds describe-db-clusters \
        --db-cluster-identifier $DB_CLUSTER_ID \
        --region $REGION \
        --query "DBClusters[0].Endpoint" \
        --output text 2>/dev/null || echo "localhost")
    export REDIS_HOST=$(aws elasticache describe-replication-groups \
        --replication-group-id $REDIS_ID \
        --region $REGION \
        --query "ReplicationGroups[0].NodeGroups[0].PrimaryEndpoint.Address" \
        --output text 2>/dev/null || echo "127.0.0.1")

    # 7.1 EFS Mount (Updated for Amazon Linux 2023 DNS resolution)
    mkdir -p .ebextensions
    cat << EOF > .ebextensions/01-efs-mount.config
packages:
  yum:
    amazon-efs-utils: []
    python3-botocore: []
commands:
  01_mount_efs:
    command: |
      mkdir -p /mnt/moodledata
      mount -t efs -o tls,_netdev ${EFS_ID}:/ /mnt/moodledata
      chown -R webapp:webapp /mnt/moodledata
      chmod 2770 /mnt/moodledata
EOF

    # 7.2 PHP ini settings
    cat << EOF > .ebextensions/02-php-settings.config
files:
  "/etc/php.d/99-moodle.ini":
    mode: "000644"
    owner: root
    group: root
    content: |
      display_errors = Off
      max_input_vars = 5000
      upload_max_filesize = 128M
      post_max_size = 128M
      max_execution_time = 300
      memory_limit = 512M
      opcache.enable = 1
EOF

    # 7.3 Nginx Configuration for Moodle
    mkdir -p .platform/nginx/conf.d/elasticbeanstalk
    envsubst '$VPC_CIDR' << 'EOF' > .platform/nginx/conf.d/elasticbeanstalk/moodle.conf
    # Trust AWS ALB proxy headers and extract Cloudflare's isolated client IP
    set_real_ip_from 10.0.0.0/8;
    set_real_ip_from $VPC_CIDR;
    real_ip_header CF-Connecting-IP;

    # Pass HTTPS protocol variables down to PHP-FPM
    fastcgi_param HTTP_X_FORWARDED_PROTO $http_x_forwarded_proto;
    fastcgi_param HTTP_X_FORWARDED_FOR $http_x_forwarded_for;
    fastcgi_param HTTPS $http_x_forwarded_proto;

    # 1. Block access to hidden files and directories (like .git, .env)
    location ~ /\.(?!well-known).* {
        deny all;
        return 404;
    }

    # 2. Block access to Moodle internal data/system directories
    location ~ ^/(?:temp|cache|local/codechecker)/ {
        deny all;
        return 404;
    }

    # 3. Handle Moodle Routing Engine framework fallback
    # We use a custom named location block to avoid conflicting with Elastic Beanstalk's main context
    location / {
        try_files $uri $uri/ /r.php$is_args$args;
    }

    location ~ (/vendor/|/node_modules/|composer\.json|/readme|/README|readme\.txt|/upgrade\.txt|/UPGRADING\.md|db/install\.xml|/fixtures/|/behat/|phpunit\.xml|\.lock|environment\.xml) {
        deny all;
        return 404;
    }
EOF

    # 7.3a Generate Self-Signed Certificates for Internal ALB-to-EC2 Encryption
    envsubst '$SSL_COUNTRY $SSL_STATE $SSL_LOCALITY $SSL_ORG $SSL_UNIT' << 'EOF' > .ebextensions/08-ssl-backend.config
packages:
  yum:
    openssl: []
commands:
  01_generate_ssl:
    command: |
      mkdir -p /etc/pki/tls/certs /etc/pki/tls/private
      openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
        -keyout /etc/pki/tls/private/internal.key \
        -out /etc/pki/tls/certs/internal.crt \
        -subj "/C=$SSL_COUNTRY/ST=$SSL_STATE/L=$SSL_LOCALITY/O=$SSL_ORG/OU=$SSL_UNIT/CN=internal"
      chmod 600 /etc/pki/tls/private/internal.key
EOF

    # Nginx HTTPS Server Block
    mkdir -p .platform/nginx/conf.d
    cat << EOF > .platform/nginx/conf.d/https.conf
server {
listen 443 ssl;
server_name localhost;

ssl_certificate /etc/pki/tls/certs/internal.crt;
ssl_certificate_key /etc/pki/tls/private/internal.key;
ssl_protocols TLSv1.2 TLSv1.3;

# Inherit the EB Moodle routing rules
include conf.d/elasticbeanstalk/*.conf;
}
EOF

    # ADDED: Adjust PHP CGI settings to make Moodle router work
    envsubst << 'EOF' > .platform/nginx/conf.d/elasticbeanstalk/php.conf
    # This file is managed by Elastic Beanstalk, overridden for Moodle 5.2 routing
    root /var/www/html/public;

    index index.php index.html index.htm;

    location ~ \.(php|phar)(/.*)?$ {
        fastcgi_split_path_info ^(.+\.(?:php|phar))(/.*)$;

        # Preserve path info before try_files clears it
        set $path_info $fastcgi_path_info;
        try_files $fastcgi_script_name $fastcgi_script_name/ /r.php$is_args$args;

        fastcgi_intercept_errors on;
        fastcgi_index  index.php;

        fastcgi_param  QUERY_STRING       $query_string;
        fastcgi_param  REQUEST_METHOD     $request_method;
        fastcgi_param  CONTENT_TYPE       $content_type;
        fastcgi_param  CONTENT_LENGTH     $content_length;

        fastcgi_param  SCRIPT_NAME        $fastcgi_script_name;
        fastcgi_param  REQUEST_URI        $request_uri;
        fastcgi_param  DOCUMENT_URI       $document_uri;
        fastcgi_param  DOCUMENT_ROOT      $document_root;
        fastcgi_param  SERVER_PROTOCOL    $server_protocol;
        fastcgi_param  REQUEST_SCHEME     $scheme;
        fastcgi_param  HTTPS              $https if_not_empty;

        fastcgi_param  GATEWAY_INTERFACE  CGI/1.1;
        fastcgi_param  SERVER_SOFTWARE    nginx/$nginx_version;

        fastcgi_param  REMOTE_ADDR        $remote_addr;
        fastcgi_param  REMOTE_PORT        $remote_port;
        fastcgi_param  SERVER_ADDR        $server_addr;
        fastcgi_param  SERVER_PORT        $server_port;
        fastcgi_param  SERVER_NAME        $server_name;

        # PHP only, required if PHP was built with --enable-force-cgi-redirect
        fastcgi_param  REDIRECT_STATUS    200;

        fastcgi_param  SCRIPT_FILENAME  $document_root$fastcgi_script_name;

        # Pass the preserved path_info variable to PHP-FPM
        fastcgi_param  PATH_INFO $path_info;
        fastcgi_pass   php-fpm;
    }
EOF

    # ADDED: Nginx Upload & Buffer Limits
    mkdir -p .platform/nginx/conf.d
    cat << EOF > .platform/nginx/conf.d/99-moodle-limits.conf
    # MIME Type Hash Optimizations
    types_hash_max_size 4096;
    types_hash_bucket_size 128;

    # Moodle FastCGI Buffer Optimizations
    fastcgi_buffer_size 64k;
    fastcgi_buffers 32 32k;
    fastcgi_busy_buffers_size 128k;
    fastcgi_max_temp_file_size 0;

    # Upload limit
    client_max_body_size 128M;
    client_body_buffer_size 128M;
EOF

    # 7.4 GitHub Actions
    mkdir -p .github/workflows
    envsubst '$REGION $APP_NAME $ENV_NAME' << 'EOF' > .github/workflows/deploy.yml
name: Deploy Moodle to AWS

on:
  workflow_dispatch:

jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - name: Checkout Code
        uses: actions/checkout@v5

      - name: Zip Moodle Code
        run: zip -r moodle-deployment.zip . -x "*.git*" ".github/*"

      - name: Configure AWS Credentials
        uses: aws-actions/configure-aws-credentials@v5   # Updated from @v4
        with:
          aws-access-key-id: ${{ secrets.AWS_ACCESS_KEY_ID }}
          aws-secret-access-key: ${{ secrets.AWS_SECRET_ACCESS_KEY }}
          aws-region: $REGION

      - name: Deploy to Elastic Beanstalk
        uses: aws-actions/aws-elasticbeanstalk-deploy@v1
        with:
          aws-region: $REGION
          application_name: $APP_NAME
          environment_name: $ENV_NAME
          version-label: ${{ github.sha }}
          deployment-package-path: moodle-deployment.zip
EOF

    # 7.5 Moodle PHP Extension Dependencies
    cat << EOF > .ebextensions/03-php-modules.config
packages:
  yum:
    php8.3-gd: []
    php8.3-intl: []
    php8.3-mbstring: []
    php8.3-soap: []
    php8.3-xml: []
    php8.3-process: []
    php8.3-opcache: []
    php8.3-pecl-redis6: []
    ghostscript: []
EOF

    # 7.6 PHP-FPM Worker Tuning
    cat << EOF > .ebextensions/04-php-fpm.config
files:
  "/etc/php-fpm.d/z-moodle.conf":
    mode: "000644"
    owner: root
    group: root
    content: |
      [www]
      pm = dynamic
      pm.max_children = 40
      pm.start_servers = 10
      pm.min_spare_servers = 10
      pm.max_spare_servers = 20
      pm.max_requests = 500
EOF

    # 7.7 EFS-Locked Cron Job
    envsubst << 'EOF' > .ebextensions/05-cron.config
files:
  "/usr/local/bin/moodle-cron.sh":
    mode: "000755"
    owner: root
    group: root
    content: |
      #!/bin/bash
      LOCK_DIR="/mnt/moodledata/cron-lock"
      if mkdir "$LOCK_DIR" 2>/dev/null; then
          sudo -u webapp /usr/bin/php /var/app/current/public/admin/cli/cron.php > /dev/null 2>&1
          rmdir "$LOCK_DIR"
      else
          if [ -n "$(find "$LOCK_DIR" -prune -mmin +15 2>/dev/null)" ]; then
              rmdir "$LOCK_DIR" 2>/dev/null
          fi
      fi

  "/etc/cron.d/moodle":
    mode: "000644"
    owner: root
    group: root
    content: |
      * * * * * root /usr/local/bin/moodle-cron.sh
EOF

    # 7.8 Environment Config
    cat << EOF > .ebextensions/00-environment.config
option_settings:
  aws:elasticbeanstalk:command:
    Timeout: 1800
EOF

    # 7.9 Document root
    cat << EOF > .ebextensions/06-document-root.config
option_settings:
  aws:elasticbeanstalk:container:php:phpini:
    document_root: /public
EOF

    # 7.10 Moodle Config Generation (Note the unquoted EOF to allow variable injection)
    envsubst '$DB_HOST $DB_USERNAME $DB_PASSWORD $WWWROOT' << 'EOF' > config.php
<?php
unset($CFG);
global $CFG;
$CFG = new stdClass();

$CFG->dbtype     = 'auroramysql';
$CFG->dblibrary  = 'native';
$CFG->dbhost     = '$DB_HOST';
$CFG->dbname     = 'moodle';
$CFG->dbuser     = '$DB_USERNAME';
$CFG->dbpass     = '$DB_PASSWORD';
$CFG->prefix     = 'mdl_';
$CFG->dboptions = array (
  'dbpersist' => 0,
  'dbport' => 3306,
  'dbsocket' => '',
  'dbcollation' => 'utf8mb4_unicode_ci',
);

$CFG->wwwroot   = '$WWWROOT';
$CFG->dataroot  = '/mnt/moodledata';
$CFG->admin     = 'admin';
$CFG->directorypermissions = 02775;

# Required for Auto-scaling setups
$CFG->localcachedir = '/tmp/moodle-localcache';

# Required for HTTPS and AWS LB setups
$CFG->sslproxy      = true;

# Required for Moodle router
$CFG->routerconfigured = true;

# Comment these for prod servers
$CFG->debug = (E_ALL | E_STRICT);
$CFG->debugdisplay = 1;

require_once(__DIR__ . '/lib/setup.php');

EOF

    # 7.11 Diagnostic PHP Script (Note the unquoted EOF)
    envsubst '$REDIS_HOST $DB_HOST $DB_USERNAME $DB_PASSWORD' << 'EOF' > sys-test.php
<?php
ini_set('display_errors', 1);
error_reporting(E_ALL);

echo "<h3>1. Testing Redis Connection (TLS Encrypted)</h3>";
$redis_endpoint = "tls://$REDIS_HOST";

if (class_exists('Redis')) {
    $redis = new Redis();
    if (@$redis->connect($redis_endpoint, 6379, 5)) {
        echo "<strong style='color:green;'>Connected securely to Redis!</strong><br>";
    } else {
        echo "<strong style='color:red;'>Failed to connect to Redis.</strong><br>";
    }
} else {
    echo "<strong style='color:red;'>Redis extension missing.</strong><br>";
}

echo "<h3>2. Testing Aurora MySQL (SSL)</h3>";
$ip = gethostbyname("$DB_HOST");
$mysqli = mysqli_init();
$mysqli->options(MYSQLI_OPT_CONNECT_TIMEOUT, 5);
if (@$mysqli->real_connect($ip, "$DB_USERNAME", "$DB_PASSWORD", "moodle", 3306, null, MYSQLI_CLIENT_SSL)) {
    echo "<strong style='color:green;'>Connected to Aurora MySQL!</strong><br>";
} else {
    echo "<strong style='color:red;'>MySQL Connection Failed: </strong>" . mysqli_connect_error() . "<br>";
}

echo "<h3>3. Testing EFS Mount</h3>";
$efs_path = '/mnt/moodledata';
if (is_dir($efs_path) && is_writable($efs_path)) {
    echo "<strong style='color:green;'>EFS Mount is writable!</strong><br>";
} else {
    echo "<strong style='color:red;'>EFS is not writable or missing.</strong><br>";
}
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
provision_acm_and_https
provision_ses
provision_eb
apply_security
generate_codebase

echo "=====================================================================" | tee -a $LOG_FILE
echo "Setup Complete! Check github_deploy_keys.json for your Action Secrets." | tee -a $LOG_FILE
