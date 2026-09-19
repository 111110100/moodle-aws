# AWS Serverless Moodle Infrastructure Deployment

This repository contains a suite of modular bash scripts designed to automate the provisioning, securing, and teardown of a highly available, auto-scaling Moodle LMS environment on AWS. Can be used to provision other projects like WordPress.

The architecture leverages AWS Elastic Beanstalk for the web tier, Amazon Aurora Serverless v2 (MySQL 8.4) for the database, Amazon ElastiCache (Redis) for session/cache management, and Amazon EFS for shared application data.

## Architecture Highlights
* **Compute:** Elastic Beanstalk (PHP 8.3 on Amazon Linux 2023) with CPU-based autoscaling (30% - 70%).
* **Database:** Aurora MySQL 8.4 Serverless v2 (0.5 to 16.0 ACU) requiring strict SSL connections.
* **Cache:** ElastiCache Redis in Cluster Mode with autoscaling for high availability.
* **Storage:** Elastic File System (EFS) mounted automatically across all subnets.
* **Security:** Automated Security Group bindings and Cloudflare-only ingress filtering.

### Amazon S3 Integration (Dedicated Storage)
While Elastic Beanstalk automatically manages a hidden S3 bucket for application versioning, this suite provisions an additional, dedicated S3 bucket specifically for Moodle.
* **Dynamic Naming:** Because S3 buckets require globally unique names, the script automatically generates the bucket name using your AWS Account ID and region (e.g., `maru-moodle-storage-<ACCOUNT_ID>-<REGION>`).
* **IAM Security:** The script applies a strict block on all public access and dynamically attaches an inline IAM policy (`MoodleS3AccessPolicy`) to the Elastic Beanstalk EC2 instance profile. This allows your Moodle application to read, write, and delete files in the bucket natively without needing hardcoded IAM keys in your PHP configuration.
* **Teardown Safety:** When executing `teardown-moodle.sh`, the script uses the `--force` flag to automatically empty all Moodle backups and media objects from the bucket before deleting it, ensuring no orphan storage charges remain.
---

## Included Scripts

### 1. `provision-moodle.sh`
The core deployment script. It provisions the entire AWS infrastructure from scratch using your Default VPC.
* Configures IAM roles, trust policies, and generates GitHub Actions deployment keys.
* Provisions EFS, Redis, Aurora Serverless, and Elastic Beanstalk.
* Applies complex cross-security-group network bindings so EC2 can securely talk to the database and cache.
* Automatically generates `.ebextensions` (for EFS mounts and PHP tuning), a GitHub Actions deployment workflow (`.github/workflows/deploy.yml`), and a PHP diagnostic script (`sys-test.php`).
* **Modular Design:** If the script hits an AWS rate limit or error, you can comment out completed steps at the bottom of the file (e.g., `# provision_efs`) and re-run it to resume exactly where it stopped.

### 2. `cloudflare-aws-lb.sh`
A security script that locks down your Elastic Beanstalk Application Load Balancer (ALB).
* Automatically fetches Cloudflare's latest IPv4 and IPv6 address ranges.
* Updates the ALB's security group inbound rules to **only** accept HTTP/HTTPS traffic originating from Cloudflare's network.
* Drops all direct-to-IP traffic, protecting your Moodle environment from DDoS attacks and unauthorized direct access.

### 3. `teardown-moodle.sh`
A safe, automated cleanup script to stop all AWS billing for the environment.
* Force-terminates the Elastic Beanstalk application and its EC2 instances.
* Deletes the Aurora DB instance and cluster (without taking a final snapshot to avoid storage costs).
* Deletes the ElastiCache Redis replication group.
* Removes EFS mount targets across all subnets and deletes the file system.

### 4. `verify-aws-billing.sh`
An auditing tool to confirm your AWS environment is completely clear of billable resources.
* Scans the active region for EC2 instances, RDS databases, ElastiCache nodes, EFS volumes, ALBs, NAT Gateways, and Elastic IPs.
* Outputs a clean, formatted table of active resources directly to the terminal while logging details to `billing_verification.log`.

---

## Usage Instructions

### Prerequisite
AWS CLI is required if you don't want to use CloudShell.

### Phase 1: Provision the Infrastructure
1. Log into your AWS Console and open **AWS CloudShell**.
2. Upload or clone these scripts into the CloudShell environment.
3. Make the scripts executable:
```bash
   chmod +x provision-moodle.sh teardown-moodle.sh verify-aws-billing.sh cloudflare-aws-lb.sh
```

4. Run the provisioning script:
```bash
./provision-moodle.sh
```

5. **Retrieve Credentials:** Once complete, open `github_deploy_keys.json` to get your `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY`. Add these to your GitHub Repository Secrets for CI/CD.
6. **Update Redis Endpoint:** Run the following command to get your Redis endpoint, and update the placeholder in the generated `sys-test.php` file:
```bash
aws elasticache describe-replication-groups --replication-group-id maru-moodle-redis --query "ReplicationGroups[0].NodeGroups[0].PrimaryEndpoint.Address" --output text
```

### Phase 2: Secure the Network (Cloudflare)

Once Elastic Beanstalk is fully provisioned and your Load Balancer is active, run the Cloudflare lockdown script:
```bash
./cloudflare-aws-lb.sh
```

*Note: Ensure your domain's DNS in Cloudflare is pointing to your Elastic Beanstalk environment URL and the proxy status is set to "Proxied" (Orange Cloud).*

### Phase 3: Deploy Moodle

1. Download the generated `.ebextensions`, `.github`, and `sys-test.php` files from CloudShell to your local machine.
2. Place them in the root of your Moodle application codebase.
3. Push your code to the `main` branch of your GitHub repository. The included GitHub Actions workflow will automatically deploy the code to Elastic Beanstalk.
4. Navigate to `https://<YOUR_DOMAIN>/sys-test.php` to verify database, cache, and storage connectivity before initiating the Moodle web installer or importing your database dump.

### Phase 4: Teardown (Stopping Charges)

When you are done testing or need to destroy the environment to stop billing:

1. Open AWS CloudShell.
2. Run the teardown script:
```bash
./teardown-moodle.sh
```

3. Wait 15 minutes for background resources to terminate, then run the verification script to audit the account:
```bash
./verify-aws-billing.sh
```

