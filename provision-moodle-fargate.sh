#!/bin/bash
# Exit immediately if a command fails, but allow specific expected duplicates (like IAM roles/rules) to bypass.
set -e 
set -o pipefail

LOG_FILE="moodle_ecs_setup.log"
REGION="ap-southeast-2"
APP_NAME="MaruMoodleLMS"
ECS_CLUSTER_NAME="maru-moodle-cluster"
TASK_FAMILY="maru-moodle-task"
SERVICE_NAME="maru-moodle-service"
ECR_REPO_NAME="maru-moodle-app"
DB_CLUSTER_ID="maru-moodle-db"
DB_INSTANCE_ID="maru-moodle-db-instance"
DB_PARAM_GROUP="moodle-aurora-mysql84-params"
REDIS_ID="maru-moodle-redis"
ALB_NAME="maru-moodle-alb"
TG_NAME="maru-moodle-tg"

> $LOG_FILE
echo "Starting Advanced AWS Infrastructure Provisioning for Moodle (ECS Fargate)..." | tee -a $LOG_FILE
echo "==========================================================================" | tee -a $LOG_FILE

setup_iam() {
    echo "1. Configuring IAM Roles for ECS Fargate..." | tee -a $LOG_FILE
    
    # 1.1 Create ECS Trust Policy
    cat << 'EOF' > ecs-trust-policy.json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": { "Service": "ecs-tasks.amazonaws.com" },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF
    
    # 1.2 ECS Task Execution Role (Allows ECS to pull from ECR and push logs to CloudWatch)
    aws iam create-role --role-name ecsTaskExecutionRole --assume-role-policy-document file://ecs-trust-policy.json 2>>$LOG_FILE || echo "   -> Execution Role exists." | tee -a $LOG_FILE
    aws iam attach-role-policy --role-name ecsTaskExecutionRole --policy-arn arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy 2>>$LOG_FILE || true

    # 1.3 ECS Task Role (Allows the Moodle container to interact with AWS APIs, like S3)
    aws iam create-role --role-name ecsTaskRole --assume-role-policy-document file://ecs-trust-policy.json 2>>$LOG_FILE || echo "   -> Task Role exists." | tee -a $LOG_FILE

    # 1.4 Create GitHub Actions Deployment User & Output Keys
    aws iam create-user --user-name github-actions-moodle-deploy 2>>$LOG_FILE || echo "   -> GitHub Deploy User already exists." | tee -a $LOG_FILE
    
    # Attach ECR/ECS Deployment Policy for GitHub Actions
    cat << 'EOF' > ecs-deploy-policy.json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "ecr:GetAuthorizationToken",
        "ecr:BatchCheckLayerAvailability",
        "ecr:GetDownloadUrlForLayer",
        "ecr:BatchGetImage",
        "ecr:InitiateLayerUpload",
        "ecr:UploadLayerPart",
        "ecr:CompleteLayerUpload",
        "ecr:PutImage"
      ],
      "Resource": "*"
    },
    {
      "Effect": "Allow",
      "Action": [
        "ecs:RegisterTaskDefinition",
        "ecs:UpdateService",
        "ecs:DescribeServices",
        "ecs:DescribeTaskDefinition"
      ],
      "Resource": "*"
    },
    {
      "Effect": "Allow",
      "Action": "iam:PassRole",
      "Resource": "*",
      "Condition": {
        "StringLike": {
          "iam:PassedToService": "ecs-tasks.amazonaws.com"
        }
      }
    }
  ]
}
EOF
    aws iam put-user-policy --user-name github-actions-moodle-deploy --policy-name ECSDeployPolicy --policy-document file://ecs-deploy-policy.json 2>>$LOG_FILE || true

    echo "   -> Generating Deployment Keys (Saved to github_deploy_keys.json)..." | tee -a $LOG_FILE
    aws iam create-access-key --user-name github-actions-moodle-deploy > github_deploy_keys.json || echo "   -> Key limit reached for user." | tee -a $LOG_FILE
}

provision_ecr() {
    echo "2. Provisioning Amazon ECR Registry..." | tee -a $LOG_FILE
    aws ecr create-repository \
        --repository-name $ECR_REPO_NAME \
        --image-scanning-configuration scanOnPush=true \
        --region $REGION >> $LOG_FILE 2>&1 || echo "   -> ECR Repository already exists." | tee -a $LOG_FILE

    ECR_URI=$(aws ecr describe-repositories --repository-names $ECR_REPO_NAME --region $REGION --query "repositories[0].repositoryUri" --output text)
    echo "   -> ECR Repository URI: $ECR_URI" | tee -a $LOG_FILE
}

provision_s3() {
    echo "3. Provisioning Dedicated S3 Bucket..." | tee -a $LOG_FILE
    ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
    S3_BUCKET_NAME="maru-moodle-storage-${ACCOUNT_ID}-${REGION}"

    aws s3api create-bucket \
        --bucket $S3_BUCKET_NAME \
        --region $REGION \
        --create-bucket-configuration LocationConstraint=$REGION >> $LOG_FILE 2>&1 || echo "   -> Bucket exists." | tee -a $LOG_FILE

    aws s3api put-public-access-block \
        --bucket $S3_BUCKET_NAME \
        --public-access-block-configuration "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true" >> $LOG_FILE 2>&1

    # Grant ECS Task Role access to this specific bucket
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
    aws iam put-role-policy --role-name ecsTaskRole --policy-name MoodleS3AccessPolicy --policy-document file://s3-access-policy.json 2>>$LOG_FILE || true
    echo "   -> Attached IAM access policy to ECS Task Role." | tee -a $LOG_FILE
}

provision_efs() {
    echo "4. Provisioning Elastic File System (EFS) for moodledata..." | tee -a $LOG_FILE
    EFS_ID=$(aws efs create-file-system --creation-token MoodleEFS-ECS --encrypted --region $REGION --query 'FileSystemId' --output text 2>>$LOG_FILE || aws efs describe-file-systems --query "FileSystems[?CreationToken=='MoodleEFS-ECS'].FileSystemId" --output text)
    echo "   -> EFS Created: $EFS_ID" | tee -a $LOG_FILE

    DEFAULT_VPC_ID=$(aws ec2 describe-vpcs --filters "Name=isDefault,Values=true" --region $REGION --query "Vpcs[0].VpcId" --output text)
    DEFAULT_SG_ID=$(aws ec2 describe-security-groups --filters "Name=vpc-id,Values=$DEFAULT_VPC_ID" "Name=group-name,Values=default" --region $REGION --query "SecurityGroups[0].GroupId" --output text)
    
    SUBNETS=$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$DEFAULT_VPC_ID" --region $REGION --query "Subnets[*].SubnetId" --output text)
    for subnet in $SUBNETS; do
        aws efs create-mount-target --file-system-id $EFS_ID --subnet-id $subnet --security-groups $DEFAULT_SG_ID 2>>$LOG_FILE || echo "   -> Mount target exists for $subnet" | tee -a $LOG_FILE
    done
    export EFS_ID
}

provision_redis() {
    echo "5. Provisioning ElastiCache (Cluster Mode Enabled & Autoscaling)..." | tee -a $LOG_FILE
    aws elasticache create-replication-group \
        --replication-group-id $REDIS_ID \
        --replication-group-description "Moodle Redis Cluster" \
        --engine redis \
        --cache-node-type cache.t4g.micro \
        --num-cache-clusters 2 \
        --automatic-failover-enabled \
        --region $REGION >> $LOG_FILE 2>&1 || echo "   -> Redis Replication Group already exists." | tee -a $LOG_FILE
}

provision_aurora() {
    echo "6. Provisioning Aurora Serverless v2 (MySQL 8.4)..." | tee -a $LOG_FILE
    aws rds create-db-cluster-parameter-group \
        --db-cluster-parameter-group-name $DB_PARAM_GROUP \
        --db-parameter-group-family aurora-mysql8.4 \
        --description "Moodle overrides for MySQL 8.4" \
        --region $REGION >> $LOG_FILE 2>&1 || echo "   -> Parameter group exists." | tee -a $LOG_FILE

    aws rds modify-db-cluster-parameter-group \
        --db-cluster-parameter-group-name $DB_PARAM_GROUP \
        --parameters "ParameterName=restrict_fk_on_non_standard_key,ParameterValue=OFF,ApplyMethod=immediate" \
        --region $REGION >> $LOG_FILE 2>&1 || true

    aws rds create-db-cluster \
        --db-cluster-identifier $DB_CLUSTER_ID \
        --engine aurora-mysql \
        --engine-version 8.4.mysql_aurora.8.4.8 \
        --master-username moodleadmin \
        --master-user-password TempPassword123\! \
        --db-cluster-parameter-group-name $DB_PARAM_GROUP \
        --serverless-v2-scaling-configuration MinCapacity=0.5,MaxCapacity=16.0 \
        --region $REGION >> $LOG_FILE 2>&1 || echo "   -> Aurora Cluster exists." | tee -a $LOG_FILE

    aws rds create-db-instance \
        --db-instance-identifier $DB_INSTANCE_ID \
        --db-cluster-identifier $DB_CLUSTER_ID \
        --engine aurora-mysql \
        --db-instance-class db.serverless \
        --region $REGION >> $LOG_FILE 2>&1 || echo "   -> Aurora Instance exists." | tee -a $LOG_FILE
}

provision_ecs() {
    echo "7. Provisioning ECS Cluster, ALB Target Group, and Security Groups..." | tee -a $LOG_FILE
    
    # 7.1 Create ECS Cluster & CloudWatch Log Group
    aws ecs create-cluster --cluster-name $ECS_CLUSTER_NAME --region $REGION >> $LOG_FILE 2>&1 || true
    aws logs create-log-group --log-group-name "/ecs/$TASK_FAMILY" --region $REGION 2>>$LOG_FILE || true

    DEFAULT_VPC_ID=$(aws ec2 describe-vpcs --filters "Name=isDefault,Values=true" --region $REGION --query "Vpcs[0].VpcId" --output text)
    SUBNET_IDS=$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$DEFAULT_VPC_ID" --region $REGION --query "Subnets[*].SubnetId" --output text | tr '\t' ',')
    SUBNET_ARRAY=($(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$DEFAULT_VPC_ID" --region $REGION --query "Subnets[*].SubnetId" --output text))

    # 7.2 Create Dedicated Security Group for ECS Fargate Tasks
    FARGATE_SG_ID=$(aws ec2 create-security-group \
        --group-name "maru-moodle-fargate-sg" \
        --description "Security Group for Moodle Fargate Tasks" \
        --vpc-id $DEFAULT_VPC_ID \
        --region $REGION \
        --query "GroupId" --output text 2>>$LOG_FILE || aws ec2 describe-security-groups --filters "Name=group-name,Values=maru-moodle-fargate-sg" --query "SecurityGroups[0].GroupId" --output text)

    aws ec2 authorize-security-group-ingress --group-id $FARGATE_SG_ID --protocol tcp --port 80 --cidr 0.0.0.0/0 --region $REGION 2>>$LOG_FILE || true

    # 7.3 Create ALB and Target Group (Target Type MUST be 'ip' for Fargate)
    ALB_ARN=$(aws elbv2 create-load-balancer \
        --name $ALB_NAME \
        --subnets ${SUBNET_ARRAY[0]} ${SUBNET_ARRAY[1]} \
        --security-groups $FARGATE_SG_ID \
        --region $REGION \
        --query "LoadBalancers[0].LoadBalancerArn" --output text 2>>$LOG_FILE || aws elbv2 describe-load-balancers --names $ALB_NAME --query "LoadBalancers[0].LoadBalancerArn" --output text)

    TG_ARN=$(aws elbv2 create-target-group \
        --name $TG_NAME \
        --protocol HTTP \
        --port 80 \
        --target-type ip \
        --vpc-id $DEFAULT_VPC_ID \
        --health-check-path "/index.php" \
        --region $REGION \
        --query "TargetGroups[0].TargetGroupArn" --output text 2>>$LOG_FILE || aws elbv2 describe-target-groups --names $TG_NAME --query "TargetGroups[0].TargetGroupArn" --output text)

    aws elbv2 create-listener \
        --load-balancer-arn $ALB_ARN \
        --protocol HTTP \
        --port 80 \
        --default-actions Type=forward,TargetGroupArn=$TG_ARN \
        --region $REGION >> $LOG_FILE 2>&1 || true

    # 7.4 Create Task Definition JSON with Native EFS Mount
    ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
    ECR_URI="$ACCOUNT_ID.dkr.ecr.$REGION.amazonaws.com/$ECR_REPO_NAME:latest"

    cat << EOF > task-definition.json
{
  "family": "$TASK_FAMILY",
  "networkMode": "awsvpc",
  "requiresCompatibilities": ["FARGATE"],
  "cpu": "1024",
  "memory": "2048",
  "executionRoleArn": "arn:aws:iam::$ACCOUNT_ID:role/ecsTaskExecutionRole",
  "taskRoleArn": "arn:aws:iam::$ACCOUNT_ID:role/ecsTaskRole",
  "containerDefinitions": [
    {
      "name": "moodle-app",
      "image": "$ECR_URI",
      "essential": true,
      "portMappings": [
        {
          "containerPort": 80,
          "hostPort": 80,
          "protocol": "tcp"
        }
      ],
      "mountPoints": [
        {
          "sourceVolume": "moodledata",
          "containerPath": "/var/www/moodledata",
          "readOnly": false
        }
      ],
      "logConfiguration": {
        "logDriver": "awslogs",
        "options": {
          "awslogs-group": "/ecs/$TASK_FAMILY",
          "awslogs-region": "$REGION",
          "awslogs-stream-prefix": "moodle"
        }
      }
    }
  ],
  "volumes": [
    {
      "name": "moodledata",
      "efsVolumeConfiguration": {
        "fileSystemId": "$EFS_ID",
        "rootDirectory": "/"
      }
    }
  ]
}
EOF

    aws ecs register-task-definition --cli-input-json file://task-definition.json --region $REGION >> $LOG_FILE 2>&1

    # 7.5 Create ECS Fargate Service
    aws ecs create-service \
        --cluster $ECS_CLUSTER_NAME \
        --service-name $SERVICE_NAME \
        --task-definition $TASK_FAMILY \
        --desired-count 2 \
        --launch-type FARGATE \
        --network-configuration "awsvpcConfiguration={subnets=[${SUBNET_IDS}],securityGroups=[${FARGATE_SG_ID}],assignPublicIp=ENABLED}" \
        --load-balancers "targetGroupArn=$TG_ARN,containerName=moodle-app,containerPort=80" \
        --region $REGION >> $LOG_FILE 2>&1 || echo "   -> ECS Service already exists." | tee -a $LOG_FILE

    # 7.6 Enable Target Tracking Autoscaling (CPU Target 60%)
    aws application-autoscaling register-scalable-target \
        --service-namespace ecs \
        --scalable-dimension ecs:service:DesiredCount \
        --resource-id service/$ECS_CLUSTER_NAME/$SERVICE_NAME \
        --min-capacity 2 \
        --max-capacity 8 \
        --region $REGION >> $LOG_FILE 2>&1 || true

    cat << 'EOF' > tracking-policy.json
{
  "TargetValue": 60.0,
  "PredefinedMetricSpecification": {
    "PredefinedMetricType": "ECSServiceAverageCPUUtilization"
  },
  "ScaleOutCooldown": 60,
  "ScaleInCooldown": 300
}
EOF

    aws application-autoscaling put-scaling-policy \
        --service-namespace ecs \
        --scalable-dimension ecs:service:DesiredCount \
        --resource-id service/$ECS_CLUSTER_NAME/$SERVICE_NAME \
        --policy-name MoodleCPUScaling \
        --policy-type TargetTrackingScaling \
        --target-tracking-scaling-policy-configuration file://tracking-policy.json \
        --region $REGION >> $LOG_FILE 2>&1 || true
}

apply_security() {
    echo "8. Binding Security Groups for DB, Redis, and EFS..." | tee -a $LOG_FILE
    DEFAULT_VPC_ID=$(aws ec2 describe-vpcs --filters "Name=isDefault,Values=true" --region $REGION --query "Vpcs[0].VpcId" --output text)
    DEFAULT_SG_ID=$(aws ec2 describe-security-groups --filters "Name=vpc-id,Values=$DEFAULT_VPC_ID" "Name=group-name,Values=default" --region $REGION --query "SecurityGroups[0].GroupId" --output text)
    FARGATE_SG_ID=$(aws ec2 describe-security-groups --filters "Name=group-name,Values=maru-moodle-fargate-sg" --region $REGION --query "SecurityGroups[0].GroupId" --output text)

    aws ec2 authorize-security-group-ingress --region $REGION --group-id $DEFAULT_SG_ID --protocol tcp --port 3306 --source-group $FARGATE_SG_ID 2>>$LOG_FILE || true
    aws ec2 authorize-security-group-ingress --region $REGION --group-id $DEFAULT_SG_ID --protocol tcp --port 6379 --source-group $FARGATE_SG_ID 2>>$LOG_FILE || true
    aws ec2 authorize-security-group-ingress --region $REGION --group-id $DEFAULT_SG_ID --protocol tcp --port 2049 --source-group $FARGATE_SG_ID 2>>$LOG_FILE || true

    aws rds modify-db-cluster --db-cluster-identifier $DB_CLUSTER_ID --vpc-security-group-ids $FARGATE_SG_ID $DEFAULT_SG_ID --apply-immediately --region $REGION >> $LOG_FILE 2>&1
    aws elasticache modify-replication-group --replication-group-id $REDIS_ID --security-group-ids $FARGATE_SG_ID $DEFAULT_SG_ID --apply-immediately --region $REGION >> $LOG_FILE 2>&1
}

generate_codebase() {
    echo "9. Generating Dockerfile & GitHub Actions Workflow..." | tee -a $LOG_FILE
    
    # 9.1 Dockerfile for Moodle on PHP 8.3 + Nginx
    cat << 'EOF' > Dockerfile
FROM php:8.3-fpm-alpine

RUN apk add --no-linux-headers --no-cache \
    nginx supervisor ghostscript freetype-dev libjpeg-turbo-dev \
    libpng-dev libzip-dev icu-dev libxml2-dev libsodium-dev \
    autoconf g++ make

RUN docker-php-ext-configure gd --with-freetype --with-jpeg \
    && docker-php-ext-install -j$(nproc) gd intl mbstring soap xml zip opcache pdo_mysql mysqli exif sodium

RUN pecl install redis && docker-php-ext-enable redis

COPY nginx.conf /etc/nginx/http.d/default.conf
COPY supervisord.conf /etc/supervisord.conf
COPY php.ini /usr/local/etc/php/conf.d/moodle.ini

RUN mkdir -p /var/www/moodledata && chown -R www-data:www-data /var/www/moodledata
WORKDIR /var/www/html
COPY public /var/www/html/public

EXPOSE 80
CMD ["/usr/bin/supervisord", "-c", "/etc/supervisord.conf"]
EOF

    # 9.2 Supervisord Config (Runs Nginx and PHP-FPM)
    cat << 'EOF' > supervisord.conf
[supervisord]
nodaemon=true
logfile=/dev/null

[program:php-fpm]
command=php-fpm -F
autostart=true
autorestart=true
stdout_logfile=/dev/stdout
stdout_logfile_maxbytes=0
stderr_logfile=/dev/stderr
stderr_logfile_maxbytes=0

[program:nginx]
command=nginx -g "daemon off;"
autostart=true
autorestart=true
stdout_logfile=/dev/stdout
stdout_logfile_maxbytes=0
stderr_logfile=/dev/stderr
stderr_logfile_maxbytes=0
EOF

    # 9.3 Nginx Configuration
    cat << 'EOF' > nginx.conf
server {
    listen 80;
    server_name _;
    root /var/www/html/public;
    index index.php index.html;

    location ~ /\.(?!well-known).* { deny all; return 404; }
    location ~ ^/(?:temp|cache|local/codechecker)/ { deny all; return 404; }
    location / { try_files $uri $uri/ /index.php$is_args$args; }

    location ~ \.php$ {
        fastcgi_split_path_info ^(.+\.php)(/.+)$;
        fastcgi_pass 127.0.0.1:9000;
        fastcgi_index index.php;
        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
        fastcgi_param PATH_INFO $fastcgi_path_info;
    }
}
EOF

    # 9.4 PHP Ini
    cat << 'EOF' > php.ini
display_errors = Off
max_input_vars = 5000
upload_max_filesize = 128M
post_max_size = 128M
max_execution_time = 300
memory_limit = 512M
opcache.enable = 1
EOF

    # 9.5 GitHub Actions Workflow for ECS Deployments
    mkdir -p .github/workflows
    cat << 'EOF' > .github/workflows/deploy.yml
name: Build and Deploy Moodle to AWS ECS Fargate
on:
  push:
    branches: [ "main" ]

jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
    - name: Checkout Code
      uses: actions/checkout@v3

    - name: Configure AWS Credentials
      uses: aws-actions/configure-aws-credentials@v2
      with:
        aws-access-key-id: ${{ secrets.AWS_ACCESS_KEY_ID }}
        aws-secret-access-key: ${{ secrets.AWS_SECRET_ACCESS_KEY }}
        aws-region: ap-southeast-2

    - name: Log in to Amazon ECR
      id: login-ecr
      uses: aws-actions/amazon-ecr-login@v1

    - name: Build, Tag, and Push Image to ECR
      env:
        ECR_REGISTRY: ${{ steps.login-ecr.outputs.registry }}
        ECR_REPOSITORY: maru-moodle-app
        IMAGE_TAG: ${{ github.sha }}
      run: |
        docker build -t $ECR_REGISTRY/$ECR_REPOSITORY:$IMAGE_TAG .
        docker push $ECR_REGISTRY/$ECR_REPOSITORY:$IMAGE_TAG

    - name: Download Task Definition
      run: |
        aws ecs describe-task-definition --task-definition maru-moodle-task --query taskDefinition > task-definition.json

    - name: Fill in the new image ID in the ECS task definition
      id: task-def
      uses: aws-actions/amazon-ecs-render-task-definition@v1
      with:
        task-definition: task-definition.json
        container-name: moodle-app
        image: ${{ steps.login-ecr.outputs.registry }}/maru-moodle-app:${{ github.sha }}

    - name: Deploy Amazon ECS task definition
      uses: aws-actions/amazon-ecs-deploy-task-definition@v1
      with:
        task-definition: ${{ steps.task-def.outputs.task-definition }}
        service: maru-moodle-service
        cluster: maru-moodle-cluster
        wait-for-service-stability: true
EOF

    echo "   -> Codebase generated locally in CloudShell." | tee -a $LOG_FILE
}

# ======================================================================
# EXECUTION MODULES
# Comment out any of the functions below with a '#' to skip that step.
# ======================================================================
setup_iam
provision_ecr
provision_s3
provision_efs
provision_redis
provision_aurora
provision_ecs
apply_security
generate_codebase

echo "==========================================================================" | tee -a $LOG_FILE
echo "Setup Complete! Check github_deploy_keys.json for your Action Secrets." | tee -a $LOG_FILE
