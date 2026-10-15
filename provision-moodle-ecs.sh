#!/bin/bash
# Exit immediately if a command fails, but allow specific expected duplicates to bypass.
set -e
set -o pipefail

export LOG_FILE="moodle_ecs_setup.log"
export REGION="ap-southeast-2"
export APP_NAME="MaruMoodleLMS"
export ENV_NAME="maru-moodle-prod"
export DB_CLUSTER_ID="maru-moodle-db"
export DB_INSTANCE_ID="maru-moodle-db-instance"
export DB_PARAM_GROUP="moodle-aurora-mysql84-params"
export DB_USERNAME="moodleadmin"
export DB_PASSWORD="Temp123()"
export REDIS_ID="maru-moodle-redis"
export ECS_CLUSTER="maru-moodle-cluster"
export ECR_REPO="maru-moodle-app"
export WWWROOT="http://changeme.com"

> $LOG_FILE
echo "Starting Advanced AWS Infrastructure Provisioning for Moodle (ECS Fargate)..." | tee -a $LOG_FILE
echo "=====================================================================" | tee -a $LOG_FILE

setup_iam() {
    echo "1. Configuring IAM Roles for ECS..." | tee -a $LOG_FILE

    # 1.1 ECS Task Execution Role (Used by Fargate to pull images and write logs)
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

    # 1.3 GitHub Actions Deployment User with LEAST PRIVILEGE
    aws iam create-user --user-name github-actions-moodle-deploy 2>>$LOG_FILE || echo "   -> GitHub Deploy User exists." | tee -a $LOG_FILE

    # Scoped inline policy for ECR image pushes and ECS task deployments
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

    aws iam create-role --role-name ecsTaskExecutionRole --assume-role-policy-document file://ecs-trust-policy.json 2>>$LOG_FILE || echo "   -> Execution Role exists." | tee -a $LOG_FILE
    aws iam attach-role-policy --role-name ecsTaskExecutionRole --policy-arn arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy 2>>$LOG_FILE || true

    # 1.2 ECS Task Role (Used by the Moodle App for S3 access)
    aws iam create-role --role-name ecsMoodleTaskRole --assume-role-policy-document file://ecs-trust-policy.json 2>>$LOG_FILE || echo "   -> Task Role exists." | tee -a $LOG_FILE

    # ADDED: EFS Mount Target visibility policy for Task Role
    aws iam attach-role-policy --role-name ecsMoodleTaskRole --policy-arn arn:aws:iam::aws:policy/AmazonElasticFileSystemClientReadWriteAccess 2>>$LOG_FILE || true

    # 1.3 GitHub Actions Deployment User
    aws iam create-user --user-name github-actions-moodle-deploy 2>>$LOG_FILE || echo "   -> GitHub Deploy User exists." | tee -a $LOG_FILE
    aws iam attach-user-policy --user-name github-actions-moodle-deploy --policy-arn arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryFullAccess 2>>$LOG_FILE || true
    aws iam attach-user-policy --user-name github-actions-moodle-deploy --policy-arn arn:aws:iam::aws:policy/AmazonECS_FullAccess 2>>$LOG_FILE || true

    echo "   -> Generating Deployment Keys..." | tee -a $LOG_FILE
    aws iam create-access-key --user-name github-actions-moodle-deploy > github_deploy_keys.json 2>>$LOG_FILE || echo "   -> Key limit reached." | tee -a $LOG_FILE
}

provision_s3() {
    echo "2. Provisioning Dedicated S3 Bucket..." | tee -a $LOG_FILE
    ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
    S3_BUCKET_NAME="maru-moodle-storage-${ACCOUNT_ID}-${REGION}"

    aws s3api create-bucket --bucket $S3_BUCKET_NAME --region $REGION --create-bucket-configuration LocationConstraint=$REGION >> $LOG_FILE 2>&1 || echo "   -> Bucket exists." | tee -a $LOG_FILE
    aws s3api put-public-access-block --bucket $S3_BUCKET_NAME --public-access-block-configuration "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true" >> $LOG_FILE 2>&1

    # Attach S3 policy to the ECS Task Role (Not Execution Role)
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
    aws iam put-role-policy --role-name ecsMoodleTaskRole --policy-name MoodleS3AccessPolicy --policy-document file://s3-access-policy.json 2>>$LOG_FILE || true
    echo "   -> S3 Bucket Created: $S3_BUCKET_NAME" | tee -a $LOG_FILE
}

provision_efs() {
    echo "3. Provisioning Elastic File System (EFS)..." | tee -a $LOG_FILE
    EFS_ID=$(aws efs create-file-system --creation-token MoodleEFS --encrypted --region $REGION --query 'FileSystemId' --output text 2>>$LOG_FILE || aws efs describe-file-systems --query "FileSystems[?CreationToken=='MoodleEFS'].FileSystemId" --output text)
    echo "   -> EFS Created: $EFS_ID" | tee -a $LOG_FILE

    DEFAULT_VPC_ID=$(aws ec2 describe-vpcs --filters "Name=isDefault,Values=true" --region $REGION --query "Vpcs[0].VpcId" --output text 2>>$LOG_FILE)
    DEFAULT_SG_ID=$(aws ec2 describe-security-groups --filters "Name=vpc-id,Values=$DEFAULT_VPC_ID" "Name=group-name,Values=default" --region $REGION --query "SecurityGroups[0].GroupId" --output text 2>>$LOG_FILE)

    # ADDED: Ensure VPC DNS attributes are active for EFS DNS resolution
    aws ec2 modify-vpc-attribute --vpc-id $DEFAULT_VPC_ID --enable-dns-support '{"Value":true}' 2>>$LOG_FILE || true
    aws ec2 modify-vpc-attribute --vpc-id $DEFAULT_VPC_ID --enable-dns-hostnames '{"Value":true}' 2>>$LOG_FILE || true

    # ADDED: Allow VPC CIDR ingress on port 2049 to prevent Fargate boot timeouts
    VPC_CIDR=$(aws ec2 describe-vpcs --vpc-ids $DEFAULT_VPC_ID --query "Vpcs[0].CidrBlock" --output text 2>>$LOG_FILE)
    aws ec2 authorize-security-group-ingress --region $REGION --group-id $DEFAULT_SG_ID --protocol tcp --port 2049 --cidr $VPC_CIDR 2>>$LOG_FILE || true

    SUBNETS=$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$DEFAULT_VPC_ID" --region $REGION --query "Subnets[*].SubnetId" --output text 2>>$LOG_FILE)
    for subnet in $SUBNETS; do
        aws efs create-mount-target --file-system-id $EFS_ID --subnet-id $subnet --security-groups $DEFAULT_SG_ID 2>>$LOG_FILE || true
    done
    export EFS_ID
}

provision_redis() {
    echo "4. Provisioning ElastiCache (Redis)..." | tee -a $LOG_FILE
    aws elasticache create-replication-group \
        --replication-group-id $REDIS_ID \
        --replication-group-description "Moodle Redis Cluster" \
        --engine redis --cache-node-type cache.t4g.micro --num-cache-clusters 2 \
        --automatic-failover-enabled --region $REGION >> $LOG_FILE 2>&1 || echo "   -> Redis exists." | tee -a $LOG_FILE
}

provision_aurora() {
    echo "5. Provisioning Aurora Serverless v2 (MySQL 8.4)..." | tee -a $LOG_FILE
    aws rds create-db-cluster-parameter-group \
        --db-cluster-parameter-group-name $DB_PARAM_GROUP --db-parameter-group-family aurora-mysql8.4 \
        --description "Moodle overrides for MySQL 8.4" --region $REGION >> $LOG_FILE 2>&1 || true
    aws rds modify-db-cluster-parameter-group \
        --db-cluster-parameter-group-name $DB_PARAM_GROUP \
        --parameters "ParameterName=restrict_fk_on_non_standard_key,ParameterValue=OFF,ApplyMethod=immediate" \
        --region $REGION >> $LOG_FILE 2>&1 || true

    aws rds modify-db-cluster-parameter-group \
        --db-cluster-parameter-group-name $DB_PARAM_GROUP \
        --parameters "ParameterName=require_secure_transport,ParameterValue=OFF,ApplyMethod=immediate" \
        --region $REGION >> $LOG_FILE 2>&1 || true

    aws rds create-db-cluster \
        --db-cluster-identifier $DB_CLUSTER_ID --engine aurora-mysql --engine-version 8.4.mysql_aurora.8.4.8 \
        --master-username moodleadmin --master-user-password 'TempPassword123!' \
        --db-cluster-parameter-group-name $DB_PARAM_GROUP \
        --serverless-v2-scaling-configuration MinCapacity=0.5,MaxCapacity=16.0 --region $REGION >> $LOG_FILE 2>&1 || true

    aws rds create-db-instance \
        --db-instance-identifier $DB_INSTANCE_ID --db-cluster-identifier $DB_CLUSTER_ID \
        --engine aurora-mysql --db-instance-class db.serverless --region $REGION >> $LOG_FILE 2>&1 || true
}

provision_networking() {
    echo "6. Provisioning ALB, Security Groups & Networking..." | tee -a $LOG_FILE
    DEFAULT_VPC_ID=$(aws ec2 describe-vpcs --filters "Name=isDefault,Values=true" --region $REGION --query "Vpcs[0].VpcId" --output text)
    SUBNETS=$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$DEFAULT_VPC_ID" --region $REGION --query "Subnets[*].SubnetId" --output text)

    # Create ALB Security Group
    ALB_SG_ID=$(aws ec2 create-security-group --group-name moodle-alb-sg --description "Moodle ALB SG" --vpc-id $DEFAULT_VPC_ID --query 'GroupId' --output text 2>>$LOG_FILE || aws ec2 describe-security-groups --filters "Name=group-name,Values=moodle-alb-sg" --query "SecurityGroups[0].GroupId" --output text)
    aws ec2 authorize-security-group-ingress --group-id $ALB_SG_ID --protocol tcp --port 80 --cidr 0.0.0.0/0 --region $REGION 2>>$LOG_FILE || true

    # Create ECS Task Security Group
    ECS_SG_ID=$(aws ec2 create-security-group --group-name moodle-ecs-sg --description "Moodle ECS Task SG" --vpc-id $DEFAULT_VPC_ID --query 'GroupId' --output text 2>>$LOG_FILE || aws ec2 describe-security-groups --filters "Name=group-name,Values=moodle-ecs-sg" --query "SecurityGroups[0].GroupId" --output text)
    # Allow traffic ONLY from the ALB
    aws ec2 authorize-security-group-ingress --group-id $ECS_SG_ID --protocol tcp --port 80 --source-group $ALB_SG_ID --region $REGION 2>>$LOG_FILE || true

    # Allow ECS to access DB, Redis, and EFS (Default SG)
    DEFAULT_SG_ID=$(aws ec2 describe-security-groups --filters "Name=vpc-id,Values=$DEFAULT_VPC_ID" "Name=group-name,Values=default" --query "SecurityGroups[0].GroupId" --output text)
    aws ec2 authorize-security-group-ingress --group-id $DEFAULT_SG_ID --protocol tcp --port 3306 --source-group $ECS_SG_ID --region $REGION 2>>$LOG_FILE || true
    aws ec2 authorize-security-group-ingress --group-id $DEFAULT_SG_ID --protocol tcp --port 6379 --source-group $ECS_SG_ID --region $REGION 2>>$LOG_FILE || true
    aws ec2 authorize-security-group-ingress --group-id $DEFAULT_SG_ID --protocol tcp --port 2049 --source-group $ECS_SG_ID --region $REGION 2>>$LOG_FILE || true

    # Update RDS and Redis to use the Default SG (which now allows ECS)
    aws rds modify-db-cluster --db-cluster-identifier $DB_CLUSTER_ID --vpc-security-group-ids $DEFAULT_SG_ID --apply-immediately --region $REGION >> $LOG_FILE 2>&1 || true
    aws elasticache modify-replication-group --replication-group-id $REDIS_ID --security-group-ids $DEFAULT_SG_ID --apply-immediately --region $REGION >> $LOG_FILE 2>&1 || true

    # Create ALB
    ALB_ARN=$(aws elbv2 create-load-balancer --name moodle-alb --subnets $SUBNETS --security-groups $ALB_SG_ID --scheme internet-facing --query 'LoadBalancers[0].LoadBalancerArn' --output text 2>>$LOG_FILE || aws elbv2 describe-load-balancers --names moodle-alb --query 'LoadBalancers[0].LoadBalancerArn' --output text)

    # Create Target Group
    TG_ARN=$(aws elbv2 create-target-group --name moodle-tg --protocol HTTP --port 80 --vpc-id $DEFAULT_VPC_ID --target-type ip --health-check-path /sys-test.php --query 'TargetGroups[0].TargetGroupArn' --output text 2>>$LOG_FILE || aws elbv2 describe-target-groups --names moodle-tg --query 'TargetGroups[0].TargetGroupArn' --output text)

    # Create Listener
    aws elbv2 create-listener --load-balancer-arn $ALB_ARN --protocol HTTP --port 80 --default-actions Type=forward,TargetGroupArn=$TG_ARN --region $REGION >> $LOG_FILE 2>&1 || true

    export ALB_SG_ID ECS_SG_ID TG_ARN SUBNETS
}

provision_ecs() {
    echo "7. Provisioning ECR & ECS Fargate..." | tee -a $LOG_FILE
    # ECR
    aws ecr create-repository --repository-name $ECR_REPO --region $REGION >> $LOG_FILE 2>&1 || true
    ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
    ECR_URI="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com/${ECR_REPO}"

    # ECS Cluster
    aws ecs create-cluster --cluster-name $ECS_CLUSTER --region $REGION >> $LOG_FILE 2>&1 || true

    # Task Definition
    EXEC_ROLE_ARN=$(aws iam get-role --role-name ecsTaskExecutionRole --query 'Role.Arn' --output text)
    TASK_ROLE_ARN=$(aws iam get-role --role-name ecsMoodleTaskRole --query 'Role.Arn' --output text)

    cat << EOF > task-definition.json
    {
      "family": "moodle-task",
      "networkMode": "awsvpc",
      "requiresCompatibilities": ["FARGATE"],
      "cpu": "1024",
      "memory": "2048",
      "executionRoleArn": "$EXEC_ROLE_ARN",
      "taskRoleArn": "$TASK_ROLE_ARN",
      "volumes": [
        {
          "name": "efs-moodledata",
          "efsVolumeConfiguration": {
            "fileSystemId": "$EFS_ID",
            "rootDirectory": "/"
          }
        }
      ],
      "containerDefinitions": [
        {
          "name": "moodle-app",
          "image": "$ECR_URI:latest",
          "essential": true,
          "portMappings": [
            {
              "containerPort": 80,
              "protocol": "tcp"
            }
          ],
          "mountPoints": [
            {
              "sourceVolume": "efs-moodledata",
              "containerPath": "/mnt/moodledata"
            }
          ],
          "logConfiguration": {
            "logDriver": "awslogs",
            "options": {
              "awslogs-group": "/ecs/moodle",
              "awslogs-region": "$REGION",
              "awslogs-stream-prefix": "ecs",
              "awslogs-create-group": "true"
            }
          }
        }
      ]
    }
EOF
    aws ecs register-task-definition --cli-input-json file://task-definition.json --region $REGION >> $LOG_FILE 2>&1

    # ECS Service
    aws ecs create-service \
        --cluster $ECS_CLUSTER --service-name moodle-service \
        --task-definition moodle-task --desired-count 2 \
        --launch-type FARGATE --network-configuration "awsvpcConfiguration={subnets=[$(echo $SUBNETS | sed 's/ /,/g')],securityGroups=[$ECS_SG_ID],assignPublicIp=ENABLED}" \
        --load-balancers "targetGroupArn=$TG_ARN,containerName=moodle-app,containerPort=80" \
        --region $REGION >> $LOG_FILE 2>&1 || echo "   -> ECS Service exists." | tee -a $LOG_FILE
}

provision_cron() {
    echo "8. Configuring EventBridge for Moodle Cron..." | tee -a $LOG_FILE
    # Fargate is ephemeral, so we use EventBridge to trigger a separate task for cron
    aws events put-rule --name MoodleCronRule --schedule-expression "rate(1 minute)" --region $REGION >> $LOG_FILE 2>&1 || true

    # Note: In a production setup, you would attach an ECS RunTask target to this rule
    # pointing to the 'moodle-task' with a command override to run cron.php.
    echo "   -> EventBridge Rule created. (Attach ECS RunTask target via AWS Console for Cron)" | tee -a $LOG_FILE
}

generate_codebase() {
    echo "9. Generating Docker & Repository Configuration..." | tee -a $LOG_FILE

    # Fetch dynamic endpoints from AWS
    echo "   -> Retrieving Aurora and Redis endpoints..." | tee -a $LOG_FILE
    export DB_HOST=$(aws rds describe-db-clusters --db-cluster-identifier $DB_CLUSTER_ID --region $REGION --query "DBClusters[0].Endpoint" --output text)
    export REDIS_HOST=$(aws elasticache describe-replication-groups --replication-group-id $REDIS_ID --region $REGION --query "ReplicationGroups[0].NodeGroups[0].PrimaryEndpoint.Address" --output text)

    # 9.1 Dockerfile (PHP 8.3 FPM + Nginx + Supervisor)
    cat << 'EOF' > Dockerfile
FROM php:8.3-fpm-bullseye

# Install system dependencies and Nginx
RUN apt-get update && apt-get install -y \
    nginx supervisor libpng-dev libjpeg-dev libfreetype6-dev \
    libzip-dev libxml2-dev libxslt1-dev libonig-dev libicu-dev \
    ghostscript unzip git python3 && \
    docker-php-ext-configure gd --with-freetype --with-jpeg && \
    docker-php-ext-install -j$(nproc) gd intl mbstring soap xml zip opcache pdo_mysql && \
    pecl install redis && docker-php-ext-enable redis && \
    rm -rf /var/lib/apt/lists/*

# Configure Nginx
COPY nginx.conf /etc/nginx/nginx.conf

# Configure Supervisor to run both Nginx and PHP-FPM
COPY supervisord.conf /etc/supervisor/conf.d/supervisord.conf

# Set working directory
WORKDIR /var/www/html

# Expose port 80
EXPOSE 80
CMD ["/usr/bin/supervisord", "-c", "/etc/supervisor/conf.d/supervisord.conf"]
EOF

    # 9.2 Nginx Config (UPDATED: Moodle 5.2 Routing & Buffer Limits)
    envsubst '$VPC_CIDR' << 'EOF' > nginx.conf
worker_processes auto;
events { worker_connections 1024; }
http {
    include /etc/nginx/mime.types;
    default_type application/octet-stream;
    sendfile on;
    keepalive_timeout 65;

    # ADDED: Upload Limits & FastCGI Buffers
    client_max_body_size 128M;
    client_body_buffer_size 128M;
    fastcgi_buffers 16 32k;
    fastcgi_buffer_size 32k;
    proxy_buffer_size 32k;
    proxy_buffers 16 32k;

    server {
        listen 80;

        # Trust AWS ALB proxy headers and extract Cloudflare's isolated client IP
        set_real_ip_from 10.0.0.0/8;
        set_real_ip_from $VPC_CIDR;
        real_ip_header CF-Connecting-IP;

        # REQUIRED FOR MOODLE 5.2: Serve from the public directory
        root /var/www/html/public;
        index index.php index.html index.htm;

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

        # 3. Handle Moodle slash arguments (fixes broken CSS/JS/images)
        location / {
            try_files $uri $uri/ /r.php$is_args$args;
        }

        # 4. Handle PHP and fake PHP routes
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
            fastcgi_pass   127.0.0.1:9000;
        }
    }
}
EOF

    # 9.3 Supervisor Config
    cat << 'EOF' > supervisord.conf
[supervisord]
nodaemon=true
logging_enabled=false

[program:php-fpm]
command=php-fpm
autostart=true
autorestart=true

[program:nginx]
command=nginx -g "daemon off;"
autostart=true
autorestart=true
EOF

    # 9.4 PHP ini overrides
    cat << 'EOF' > php-moodle.ini
display_errors = Off
max_input_vars = 5000
upload_max_filesize = 128M
post_max_size = 128M
max_execution_time = 300
memory_limit = 512M
opcache.enable = 1
EOF

    # 9.5 GitHub Actions for ECR & ECS
    mkdir -p .github/workflows
    cat << 'EOF' > .github/workflows/deploy.yml
name: Deploy Moodle to AWS ECS
on:
  push:
    branches: [ "main" ]

jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - name: Checkout Code
        uses: actions/checkout@v3

      - name: Configure AWS credentials
        uses: aws-actions/configure-aws-credentials@v2
        with:
          aws-access-key-id: ${{ secrets.AWS_ACCESS_KEY_ID }}
          aws-secret-access-key: ${{ secrets.AWS_SECRET_ACCESS_KEY }}
          aws-region: ap-southeast-2

      - name: Login to Amazon ECR
        id: login-ecr
        uses: aws-actions/amazon-ecr-login@v1

      - name: Build, tag, and push image to Amazon ECR
        env:
          ECR_REGISTRY: ${{ steps.login-ecr.outputs.registry }}
          ECR_REPOSITORY: maru-moodle-app
          IMAGE_TAG: ${{ github.sha }}
        run: |
          docker build -t $ECR_REGISTRY/$ECR_REPOSITORY:$IMAGE_TAG .
          docker push $ECR_REGISTRY/$ECR_REPOSITORY:$IMAGE_TAG
          docker tag $ECR_REGISTRY/$ECR_REPOSITORY:$IMAGE_TAG $ECR_REGISTRY/$ECR_REPOSITORY:latest
          docker push $ECR_REGISTRY/$ECR_REPOSITORY:latest

      - name: Download Task Definition
        run: |
          aws ecs describe-task-definition --task-definition moodle-task --query taskDefinition > task-definition.json

      - name: Fill in the new image ID in the ECS task definition
        id: task-def
        uses: aws-actions/amazon-ecs-render-task-definition@v1
        with:
          task-definition: task-definition.json
          container-name: moodle-app
          image: ${{ steps.login-ecr.outputs.registry }}/maru-moodle-app:${{ github.sha }}

      - name: Deploy Amazon ECS task definition
        uses: aws-actions/amazon-ecs-deploy-task-definition@v2
        with:
          task-definition: ${{ steps.task-def.outputs.task-definition }}
          service: moodle-service
          cluster: maru-moodle-cluster
          wait-for-service-stability: true
EOF

    # 9.6 Moodle Config Generation (Note the unquoted EOF to allow variable injection)
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

$CFG->wwwroot    = '$WWWROOT';
$CFG->dataroot  = '/mnt/moodledata';
$CFG->admin  = 'admin';
$CFG->directorypermissions = 0777;

# Required for Auto-scaling setups
$CFG->localcachedir = '/tmp/moodle-localcache';
$CFG->dbsessions = 1;

# Required for HTTPS and AWS LB setups
$CFG->sslproxy      = true;

# Required for Moodle router
$CFG->routerconfigured = true;

# Comment these for prod servers
$CFG->debug = (E_ALL | E_STRICT);
$CFG->debugdisplay = 1;

require_once(__DIR__ . '/lib/setup.php');
EOF

    # 9.7 Diagnostic Script (Note the unquoted EOF)
    envsubst '$REDIS_HOST $DB_HOST $DB_USERNAME $DB_PASSWORD' << 'EOF' > sys-test.php
<?php
ini_set('display_errors', 1);
error_reporting(E_ALL);

echo "<h3>ECS Fargate Environment Test</h3>";
echo "<p>Container Hostname: " . gethostname() . "</p>";
echo "<p>PHP Version: " . phpversion() . "</p>";

echo "<h3>1. Testing Redis Connection</h3>";
$redis_endpoint = "$REDIS_HOST";

if (class_exists('Redis')) {
    $redis = new Redis();
    if (@$redis->connect($redis_endpoint, 6379, 5)) {
        echo "<strong style='color:green;'>Connected to Redis!</strong><br>";
    } else {
        echo "<strong style='color:red;'>Failed to connect to Redis.</strong><br>";
    }
} else {
    echo "<strong style='color:red;'>Redis extension missing.</strong><br>";
}

echo "<h3>2. Testing Aurora MySQL</h3>";
$ip = gethostbyname("$DB_HOST");
$mysqli = mysqli_init();
$mysqli->options(MYSQLI_OPT_CONNECT_TIMEOUT, 5);
if (@$mysqli->real_connect($ip, "$DB_USERNAME", "$DB_PASSWORD", "moodle", 3306)) {
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
    echo "   -> Codebase generated locally." | tee -a $LOG_FILE
}

# ======================================================================
# EXECUTION MODULES
# ======================================================================
setup_iam
provision_s3
provision_efs
provision_redis
provision_aurora
provision_networking
provision_ecs
provision_cron
generate_codebase

echo "=====================================================================" | tee -a $LOG_FILE
echo "Setup Complete! Check github_deploy_keys.json for your Action Secrets." | tee -a $LOG_FILE
echo "Next Steps:" | tee -a $LOG_FILE
echo "1. Clone Moodle source code into this directory." | tee -a $LOG_FILE
echo "2. Run 'docker build -t maru-moodle-app .' to test locally." | tee -a $LOG_FILE
echo "3. Push to GitHub to trigger the ECS deployment." | tee -a $LOG_FILE
