#!/bin/bash
# Exit immediately if any command returns a non-zero status
set -e 
set -o pipefail

LOG_FILE="moodle_aws_teardown.log"
REGION="ap-southeast-2"
APP_NAME="MaruMoodleLMS"
DB_CLUSTER_ID="maru-moodle-db"
DB_INSTANCE_ID="maru-moodle-db-instance"
REDIS_ID="maru-moodle-redis"

# Clear previous log
> $LOG_FILE

echo "Starting AWS Infrastructure Teardown. All API responses logged to $LOG_FILE" | tee -a $LOG_FILE
echo "------------------------------------------------------------------------" | tee -a $LOG_FILE

teardown_eb() {
    echo "1. Initiating Elastic Beanstalk Deletion..." | tee -a $LOG_FILE
    # Using --terminate-env-by-force deletes the app and all associated environments/EC2s
    aws elasticbeanstalk delete-application \
        --application-name $APP_NAME \
        --terminate-env-by-force \
        --region $REGION >> $LOG_FILE 2>&1
    echo "   -> EB Application and Environment deletion initiated." | tee -a $LOG_FILE
}

teardown_aurora_instance() {
    echo "2. Deleting Aurora DB Instance (This can take 5-15 mins)..." | tee -a $LOG_FILE
    # The instance must be deleted before the cluster. We skip the final snapshot to prevent storage costs.
    aws rds delete-db-instance \
        --db-instance-identifier $DB_INSTANCE_ID \
        --skip-final-snapshot \
        --region $REGION >> $LOG_FILE 2>&1
    
    echo "   -> Waiting for AWS to finish deleting the DB Instance..." | tee -a $LOG_FILE
    aws rds wait db-instance-deleted \
        --db-instance-identifier $DB_INSTANCE_ID \
        --region $REGION >> $LOG_FILE 2>&1
    echo "   -> DB Instance successfully deleted." | tee -a $LOG_FILE
}

teardown_aurora_cluster() {
    echo "3. Deleting Aurora DB Cluster..." | tee -a $LOG_FILE
    aws rds delete-db-cluster \
        --db-cluster-identifier $DB_CLUSTER_ID \
        --skip-final-snapshot \
        --region $REGION >> $LOG_FILE 2>&1
    echo "   -> DB Cluster deletion initiated." | tee -a $LOG_FILE
}

teardown_redis() {
    echo "4. Deleting ElastiCache Redis..." | tee -a $LOG_FILE
    aws elasticache delete-cache-cluster \
        --cache-cluster-id $REDIS_ID \
        --region $REGION >> $LOG_FILE 2>&1
    echo "   -> Redis deletion initiated." | tee -a $LOG_FILE
}

teardown_efs() {
    echo "5. Deleting Elastic File System (EFS)..." | tee -a $LOG_FILE
    # Fetch EFS ID dynamically based on the creation token from the provision script
    EFS_ID=$(aws efs describe-file-systems --region $REGION --query "FileSystems[?CreationToken=='MoodleEFS'].FileSystemId" --output text)
    
    if [ "$EFS_ID" == "" ] || [ "$EFS_ID" == "None" ]; then
        echo "   -> EFS not found or already deleted. Skipping." | tee -a $LOG_FILE
        return
    fi

    echo "   -> Found EFS ID: $EFS_ID. Checking for mount targets..." | tee -a $LOG_FILE
    TARGETS=$(aws efs describe-mount-targets --file-system-id $EFS_ID --region $REGION --query "MountTargets[*].MountTargetId" --output text)
    
    for target in $TARGETS; do
        echo "   -> Deleting mount target: $target" | tee -a $LOG_FILE
        aws efs delete-mount-target --mount-target-id $target --region $REGION >> $LOG_FILE 2>&1
    done
    
    echo "   -> Waiting for network interfaces to release..." | tee -a $LOG_FILE
    sleep 15 
    
    aws efs delete-file-system --file-system-id $EFS_ID --region $REGION >> $LOG_FILE 2>&1
    echo "   -> EFS deleted." | tee -a $LOG_FILE
}

teardown_s3() {
    echo "X. Deleting Dedicated S3 Bucket..." | tee -a $LOG_FILE
    ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
    S3_BUCKET_NAME="maru-moodle-storage-${ACCOUNT_ID}-${REGION}"

    # The --force flag automatically deletes all objects inside the bucket before deleting the bucket itself
    aws s3 rb s3://$S3_BUCKET_NAME --force >> $LOG_FILE 2>&1 || echo "   -> S3 Bucket already deleted or not found." | tee -a $LOG_FILE
    echo "   -> S3 Bucket deleted." | tee -a $LOG_FILE
}

# ======================================================================
# EXECUTION MODULES
# Comment out any of the functions below with a '#' to skip that step.
# ======================================================================
teardown_eb
teardown_aurora_instance
teardown_aurora_cluster
teardown_redis
teardown_efs
teardown_s3

echo "------------------------------------------------------------------------" | tee -a $LOG_FILE
echo "Teardown script completed without errors." | tee -a $LOG_FILE
