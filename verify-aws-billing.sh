#!/bin/bash
REGION="ap-southeast-2"
LOG_FILE="billing_verification.log"

# Clear previous log
> $LOG_FILE

echo "=================================================" | tee -a $LOG_FILE
echo " AWS Billing Verification - Resource Status Check" | tee -a $LOG_FILE
echo " Region: $REGION" | tee -a $LOG_FILE
echo "=================================================" | tee -a $LOG_FILE
echo "" | tee -a $LOG_FILE

# Helper function to parse output and log status
check_service() {
    local SERVICE_NAME="$1"
    local CMD_OUTPUT="$2"

    # Print the service name padded to 35 characters
    printf "%-35s" "Checking $SERVICE_NAME..." | tee -a $LOG_FILE
    
    if [ -z "$CMD_OUTPUT" ] || [ "$CMD_OUTPUT" == "None" ]; then
        echo "[ CLEAR ]" | tee -a $LOG_FILE
    else
        echo "[ ACTIVE RESOURCES FOUND ]" | tee -a $LOG_FILE
        # Indent the active resources for readability
        echo "$CMD_OUTPUT" | sed 's/^/    -> /' | tee -a $LOG_FILE
    fi
}

# 1. EC2 Instances (Excluding terminated instances which don't bill)
EC2_OUT=$(aws ec2 describe-instances --region $REGION --query "Reservations[*].Instances[?State.Name!='terminated'].{ID:InstanceId,State:State.Name}" --output text 2>>$LOG_FILE)
check_service "EC2 Instances" "$EC2_OUT"

# 2. RDS Clusters
RDS_CLUSTER_OUT=$(aws rds describe-db-clusters --region $REGION --query "DBClusters[*].{ID:DBClusterIdentifier,Status:Status}" --output text 2>>$LOG_FILE)
check_service "RDS Clusters" "$RDS_CLUSTER_OUT"

# 3. RDS Instances
RDS_INST_OUT=$(aws rds describe-db-instances --region $REGION --query "DBInstances[*].{ID:DBInstanceIdentifier,Status:DBInstanceStatus}" --output text 2>>$LOG_FILE)
check_service "RDS Instances" "$RDS_INST_OUT"

# 4. ElastiCache (Redis)
REDIS_OUT=$(aws elasticache describe-cache-clusters --region $REGION --query "CacheClusters[*].{ID:CacheClusterId,Status:CacheClusterStatus}" --output text 2>>$LOG_FILE)
check_service "ElastiCache (Redis)" "$REDIS_OUT"

# 5. Elastic File Systems (EFS)
EFS_OUT=$(aws efs describe-file-systems --region $REGION --query "FileSystems[*].{ID:FileSystemId,Token:CreationToken}" --output text 2>>$LOG_FILE)
check_service "Elastic File Systems" "$EFS_OUT"

# 6. Elastic Load Balancers
ELB_OUT=$(aws elbv2 describe-load-balancers --region $REGION --query "LoadBalancers[*].{Name:LoadBalancerName,State:State.Code}" --output text 2>>$LOG_FILE)
check_service "Elastic Load Balancers" "$ELB_OUT"

# 7. NAT Gateways (Excluding deleted gateways)
NAT_OUT=$(aws ec2 describe-nat-gateways --region $REGION --query "NatGateways[?State!='deleted'].{ID:NatGatewayId,State:State}" --output text 2>>$LOG_FILE)
check_service "NAT Gateways" "$NAT_OUT"

# 8. Elastic IPs (EIP)
EIP_OUT=$(aws ec2 describe-addresses --region $REGION --query "Addresses[*].{IP:PublicIp,AllocationId:AllocationId}" --output text 2>>$LOG_FILE)
check_service "Elastic IPs" "$EIP_OUT"

echo "" | tee -a $LOG_FILE
echo "=================================================" | tee -a $LOG_FILE
echo "Verification complete. Results saved to $LOG_FILE" | tee -a $LOG_FILE
