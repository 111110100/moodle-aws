# AWS CLI Operations Cheat Sheet (Maru Academy Moodle)

Use these commands in AWS CloudShell to quickly check the health, status, and configuration of your Moodle infrastructure. Note that `--region ap-southeast-2` is appended to ensure commands target the correct Sydney region.

## 1. Elastic Beanstalk (Moodle Application)

**Check Overall Environment Health and Status**
```bash
aws elasticbeanstalk describe-environments \
    --application-name MaruMoodleLMS \
    --region ap-southeast-2 \
    --query "Environments[*].[EnvironmentName, Status, Health, HealthStatus]" \
    --output table
```

## 2. EC2 Instances (Web Servers)

**Check Status of Live Web Servers**
Because Elastic Beanstalk automatically scales instances in and out, you first need to extract the active Environment Name to find the current running instances.
```bash
# 1. Get the active environment name
ENV_NAME=$(aws elasticbeanstalk describe-environments \
    --application-name MaruMoodleLMS \
    --region ap-southeast-2 \
    --query "Environments[?Status=='Ready'].EnvironmentName | [0]" \
    --output text)

# 2. List instances and their running state
aws ec2 describe-instances \
    --filters "Name=tag:elasticbeanstalk:environment-name,Values=$ENV_NAME" \
    --region ap-southeast-2 \
    --query "Reservations[*].Instances[*].[InstanceId, State.Name, PrivateIpAddress, PublicIpAddress]" \
    --output table
```

## 3. Aurora MySQL (Database)

**Check Database Cluster Health**
```bash
aws rds describe-db-clusters \
    --db-cluster-identifier maru-moodle-db \
    --region ap-southeast-2 \
    --query "DBClusters[*].[DBClusterIdentifier, Status, Endpoint]" \
    --output table
```

**Check Live RDS to S3 Export Tasks**
```bash
aws rds describe-export-tasks \
    --region ap-southeast-2 \
    --query "ExportTasks[*].[ExportTaskIdentifier, Status, PercentProgress, TotalExtractedDataInGB]" \
    --output table
```
**Trigger the Lambda function immediately using the AWS CLI, bypassing the EventBridge schedule.**
```bash
aws lambda invoke \
  --function-name export-rds-snapshot-to-s3 \
  --region ap-southeast-2 \
  response.json && cat response.json
```
**Check the Live Export Progress in RDS**
```bash
aws rds describe-export-tasks \
  --region ap-southeast-2 \
  --query "ExportTasks[*].[ExportTaskIdentifier, Status, PercentProgress, TotalExtractedDataInGB]" \
  --output table
```

## 4. ElastiCache Redis (Session & Cache)

**Check Redis Cluster Status and Node Health**
```bash
aws elasticache describe-replication-groups \
    --replication-group-id maru-moodle-redis \
    --region ap-southeast-2 \
    --query "ReplicationGroups[*].[ReplicationGroupId, Status, NodeGroups[0].PrimaryEndpoint.Address]" \
    --output table
```

## 5. Elastic File System (EFS - Shared Storage)

**Check EFS Lifecycle State & Mount Targets**
To check if the mount targets are fully available across your subnets, you first extract the dynamic File System ID.
```bash
# 1. Extract the EFS ID
EFS_ID=$(aws efs describe-file-systems \
    --region ap-southeast-2 \
    --query "FileSystems[?CreationToken=='MoodleEFS'].FileSystemId | [0]" \
    --output text)

# 2. Check the primary file system status
aws efs describe-file-systems \
    --file-system-id $EFS_ID \
    --region ap-southeast-2 \
    --query "FileSystems[*].[FileSystemId, LifeCycleState, NumberOfMountTargets]" \
    --output table

# 3. Check subnet mount target statuses
aws efs describe-mount-targets \
    --file-system-id $EFS_ID \
    --region ap-southeast-2 \
    --query "MountTargets[*].[MountTargetId, SubnetId, LifeCycleState, IpAddress]" \
    --output table
```

## 6. S3 (Backups & Storage)

**List Recent RDS Backups**
Check if the Parquet files have successfully landed in your destination bucket folder.
```bash
aws s3 ls s3://maru-moodle-data-2026/RDS_Backups/ --recursive --human-readable
```

## 7. Amazon SES (Transactional Email & MFA)

**Check Domain Identity Verification Status**
```bash
aws ses get-identity-verification-attributes \
    --identities "changeme.com" "no-reply@changeme.com" \
    --region ap-southeast-2 \
    --query "VerificationAttributes" \
    --output json
```

**Check SES Sending Quotas & Sandbox Status**
```bash
aws ses get-send-quota \
    --region ap-southeast-2 \
    --output table
```

## 8. Lambda & EventBridge (Automation)

**Check Lambda Function Configuration & State**
```bash
aws lambda get-function \
    --function-name export-rds-snapshot-to-s3 \
    --region ap-southeast-2 \
    --query "Configuration.[State, LastUpdateStatus, Timeout, Role]" \
    --output table
```
