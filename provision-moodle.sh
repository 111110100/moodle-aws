#!/bin/bash
# Exit immediately if a command fails, but allow specific expected duplicates (like IAM roles/rules) to bypass.
set -e
set -o pipefail

export LOG_FILE="moodle_aws_setup.log"
export REGION="ap-southeast-2"
export APP_NAME="MaruMoodleLMS"
export ENV_NAME="MaruMoodle-Prod"
export DB_CLUSTER_ID="maru-moodle-db"
export DB_INSTANCE_ID="maru-moodle-db-instance"
export DB_PARAM_GROUP="moodle-aurora-mysql84-params"
export DB_USERNAME="moodleadmin"
export DB_PASSWORD="Temp123()"
export REDIS_ID="maru-moodle-redis"
export WWWROOT="http://changeme.com"

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

    # 1.2 Create EB EC2 Role & Attach Managed Policies (Including SSM Default Policy for Session Manager)
    aws iam create-role --role-name aws-elasticbeanstalk-ec2-role --assume-role-policy-document file://ec2-trust-policy.json 2>>$LOG_FILE || echo "   -> Role already exists." | tee -a $LOG_FILE
    aws iam attach-role-policy --role-name aws-elasticbeanstalk-ec2-role --policy-arn arn:aws:iam::aws:policy/AWSElasticBeanstalkWebTier 2>>$LOG_FILE || true
    aws iam attach-role-policy --role-name aws-elasticbeanstalk-ec2-role --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedEC2InstanceDefaultPolicy 2>>$LOG_FILE || true
    # ADDED: EFS Mount Target visibility policy
    aws iam attach-role-policy --role-name aws-elasticbeanstalk-ec2-role --policy-arn arn:aws:iam::aws:policy/AmazonElasticFileSystemClientReadWriteAccess 2>>$LOG_FILE || true

    # 1.3 Create Instance Profile and link Role
    aws iam create-instance-profile --instance-profile-name aws-elasticbeanstalk-ec2-role 2>>$LOG_FILE || echo "   -> Instance profile exists." | tee -a $LOG_FILE
    aws iam add-role-to-instance-profile --instance-profile-name aws-elasticbeanstalk-ec2-role --role-name aws-elasticbeanstalk-ec2-role 2>>$LOG_FILE || true

    # 1.4 Create GitHub Actions Deployment User & Output Keys
    aws iam create-user --user-name github-actions-moodle-deploy 2>>$LOG_FILE || echo "   -> GitHub Deploy User already exists." | tee -a $LOG_FILE
    aws iam attach-user-policy --user-name github-actions-moodle-deploy --policy-arn arn:aws:iam::aws:policy/AWSElasticBeanstalkAdministrator 2>>$LOG_FILE || true

    echo "   -> Generating Deployment Keys (Saved to github_deploy_keys.json)..." | tee -a $LOG_FILE
    aws iam create-access-key --user-name github-actions-moodle-deploy > github_deploy_keys.json || echo "   -> Key limit reached for user." | tee -a $LOG_FILE

    # 1.4 Create GitHub Actions Deployment User with LEAST PRIVILEGE
    aws iam create-user --user-name github-actions-moodle-deploy 2>>$LOG_FILE || echo "   -> GitHub Deploy User already exists." | tee -a $LOG_FILE

    # Scoped inline policy restricting the user strictly to EB deployment commands
    cat << 'EOF' > eb-deploy-policy.json
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
        "arn:aws:elasticbeanstalk:ap-southeast-2:*:application/MaruMoodleLMS",
        "arn:aws:elasticbeanstalk:ap-southeast-2:*:environment/MaruMoodleLMS/*",
        "arn:aws:elasticbeanstalk:ap-southeast-2:*:applicationversion/MaruMoodleLMS/*",
        "arn:aws:s3:::elasticbeanstalk-ap-southeast-2-*",
        "arn:aws:s3:::elasticbeanstalk-ap-southeast-2-*/*"
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
    aws iam put-user-policy --user-name github-actions-moodle-deploy --policy-name EBDeployPolicy --policy-document file://eb-deploy-policy.json 2>>$LOG_FILE || true
}

provision_s3() {
    echo "2. Provisioning Dedicated S3 Bucket..." | tee -a $LOG_FILE

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

provision_efs() {
    echo "3. Provisioning Elastic File System (EFS) & Subnet Mounts..." | tee -a $LOG_FILE
    EFS_ID=$(aws efs create-file-system --creation-token MoodleEFS --encrypted --region $REGION --query 'FileSystemId' --output text 2>>$LOG_FILE || aws efs describe-file-systems --query "FileSystems[?CreationToken=='MoodleEFS'].FileSystemId" --output text)
    echo "   -> EFS Created: $EFS_ID" | tee -a $LOG_FILE

    # Get Default VPC and Security Group
    DEFAULT_VPC_ID=$(aws ec2 describe-vpcs --filters "Name=isDefault,Values=true" --region $REGION --query "Vpcs[0].VpcId" --output text 2>>$LOG_FILE)
    DEFAULT_SG_ID=$(aws ec2 describe-security-groups --filters "Name=vpc-id,Values=$DEFAULT_VPC_ID" "Name=group-name,Values=default" --region $REGION --query "SecurityGroups[0].GroupId" --output text 2>>$LOG_FILE)

    # ADDED: Ensure VPC DNS attributes are active for EFS DNS resolution
    aws ec2 modify-vpc-attribute --vpc-id $DEFAULT_VPC_ID --enable-dns-support '{"Value":true}' 2>>$LOG_FILE || true
    aws ec2 modify-vpc-attribute --vpc-id $DEFAULT_VPC_ID --enable-dns-hostnames '{"Value":true}' 2>>$LOG_FILE || true

    # ADDED: Allow VPC CIDR ingress on port 2049 to prevent EB boot timeouts
    VPC_CIDR=$(aws ec2 describe-vpcs --vpc-ids $DEFAULT_VPC_ID --query "Vpcs[0].CidrBlock" --output text 2>>$LOG_FILE)
    aws ec2 authorize-security-group-ingress --region $REGION --group-id $DEFAULT_SG_ID --protocol tcp --port 2049 --cidr $VPC_CIDR 2>>$LOG_FILE || true

    # Create Mount Targets in all Default Subnets
    SUBNETS=$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$DEFAULT_VPC_ID" --region $REGION --query "Subnets[*].SubnetId" --output text 2>>$LOG_FILE)
    for subnet in $SUBNETS; do
        aws efs create-mount-target --file-system-id $EFS_ID --subnet-id $subnet --security-groups $DEFAULT_SG_ID 2>>$LOG_FILE || echo "   -> Mount target already exists for $subnet" | tee -a $LOG_FILE
    done
    export EFS_ID
}

provision_redis() {
    echo "4. Provisioning ElastiCache (Cluster Mode Enabled & Autoscaling)..." | tee -a $LOG_FILE
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
    echo "5. Provisioning Aurora Serverless v2 (MySQL 8.4)..." | tee -a $LOG_FILE

    # 4.1 Create Custom DB Cluster Parameter Group to disable strict FK checks in MySQL 8.4
    aws rds create-db-cluster-parameter-group \
        --db-cluster-parameter-group-name $DB_PARAM_GROUP \
        --db-parameter-group-family aurora-mysql8.4 \
        --description "Moodle overrides for MySQL 8.4" \
        --region $REGION >> $LOG_FILE 2>&1 || echo "   -> Parameter group exists." | tee -a $LOG_FILE

    aws rds modify-db-cluster-parameter-group \
        --db-cluster-parameter-group-name $DB_PARAM_GROUP \
        --parameters "ParameterName=restrict_fk_on_non_standard_key,ParameterValue=OFF,ApplyMethod=immediate" \
        --region $REGION >> $LOG_FILE 2>&1 || true

    # 4.2 Provision Cluster and Instance
    aws rds create-db-cluster \
        --db-cluster-identifier $DB_CLUSTER_ID \
        --engine aurora-mysql \
        --engine-version 8.4.mysql_aurora.8.4.8 \
        --master-username $DB_USERNAME \
        --master-user-password $DB_PASSWORD \
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

provision_eb() {
    echo "6. Provisioning Elastic Beanstalk (CPU Autoscaling: 30%-70%)..." | tee -a $LOG_FILE
    aws elasticbeanstalk create-application --application-name $APP_NAME --region $REGION >> $LOG_FILE 2>&1 || true

    # Generate EB Autoscaling Options
    cat << 'EOF' > eb-options.json
[
  {"Namespace": "aws:autoscaling:launchconfiguration", "OptionName": "IamInstanceProfile", "Value": "aws-elasticbeanstalk-ec2-role"},
  {"Namespace": "aws:ec2:instances", "OptionName": "InstanceTypes", "Value": "t4g.medium, c7g.large"},
  {"Namespace": "aws:autoscaling:asg", "OptionName": "MinSize", "Value": "2"},
  {"Namespace": "aws:autoscaling:asg", "OptionName": "MaxSize", "Value": "6"},
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

apply_security() {
    echo "7. Applying Network Security Group Bindings..." | tee -a $LOG_FILE
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
    echo "8. Generating Repository Configuration Files..." | tee -a $LOG_FILE

    # Fetch dynamic endpoints from AWS
    echo "   -> Retrieving Aurora and Redis endpoints..." | tee -a $LOG_FILE
    export DB_HOST=$(aws rds describe-db-clusters --db-cluster-identifier $DB_CLUSTER_ID --region $REGION --query "DBClusters[0].Endpoint" --output text)
    export REDIS_HOST=$(aws elasticache describe-replication-groups --replication-group-id $REDIS_ID --region $REGION --query "ReplicationGroups[0].NodeGroups[0].PrimaryEndpoint.Address" --output text)

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
      mount -t efs -o tls ${EFS_ID}:/ /mnt/moodledata
      chown -R webapp:webapp /mnt/moodledata
      chmod 777 /mnt/moodledata
EOF

    # 7.2 PHP ini settings
    cat << 'EOF' > .ebextensions/02-php-settings.config
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
    cat << 'EOF' > .platform/nginx/conf.d/elasticbeanstalk/moodle.conf
    # Trust AWS ALB proxy headers and extract Cloudflare's isolated client IP
    set_real_ip_from 10.0.0.0/8;
    real_ip_header X-Forwarded-For;
    real_ip_recursive on;

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

    # ADDED: Adjust PHP CGI settings to make Moodle router work
    cat << 'EOF' > .platform/nginx/conf.d/elasticbeanstalk/php.conf
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
    cat << 'EOF' > .platform/nginx/conf.d/99-moodle-limits.conf
    client_max_body_size 128M;
    client_body_buffer_size 128M;
    fastcgi_buffers 16 32k;
    fastcgi_buffer_size 32k;
    proxy_buffer_size 32k;
    proxy_buffers 16 32k;
EOF

    # 7.4 GitHub Actions
    mkdir -p .github/workflows
    envsubst '$APP_NAME $ENV_NAME' << 'EOF' > .github/workflows/deploy.yml
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
        application_name: $APP_NAME
        environment_name: $ENV_NAME
        version_label: ${{ github.sha }}
        region: ap-southeast-2
        deployment_package: HEAD
EOF

    # 7.5 Moodle PHP Extension Dependencies
    cat << 'EOF' > .ebextensions/03-php-modules.config
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
    cat << 'EOF' > .ebextensions/04-php-fpm.config
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
    cat << 'EOF' > .ebextensions/05-cron.config
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
    cat << 'EOF' > .ebextensions/00-environment.config
option_settings:
  aws:elasticbeanstalk:command:
    Timeout: 1800
EOF

    # 7.9 Document root
    cat << 'EOF' > .ebextensions/06-document-root.config
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

$CFG->directorypermissions = 0777;

// Tell Moodle to pull the true IP directly from Cloudflare's isolated header
$CFG->getremoteaddrconf = 'HTTP_CF_CONNECTING_IP';

# Required for Auto-scaling setups
$CFG->localcachedir = '/tmp/moodle-localcache';
$CFG->dbsessions    = 1;

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

    # 7.X Override the default Elastic Beanstalk PHP handler to support Moodle routing
    cat << 'EOF' > .platform/nginx/conf.d/elasticbeanstalk/php.conf
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
