# AWS Serverless Moodle Infrastructure Deployment

This repository contains a suite of modular bash scripts designed to automate the provisioning, securing, and teardown of a highly available, auto-scaling Moodle LMS environment on AWS. It is optimized for Moodle 5.2+ and can be adapted to provision other projects like WordPress.

The architecture leverages AWS Elastic Beanstalk for the web tier, Amazon Aurora Serverless v2 (MySQL 8.4) for the database, Amazon ElastiCache (Redis) for session/cache management, and Amazon EFS for shared application data.

## Architecture Highlights

* **Compute:** Elastic Beanstalk (PHP 8.3 on Amazon Linux 2023) with CPU-based autoscaling (30% - 70%).
* **Web Server:** Custom Nginx overrides handling Moodle 5.2's `/public` document root, ensuring correct slash argument routing and `$path_info` preservation for REST APIs.
* **Database:** Aurora MySQL 8.4 Serverless v2 (0.5 to 16.0 ACU) requiring strict SSL connections.
* **Cache:** ElastiCache Redis in Cluster Mode with autoscaling for high availability.
* **Storage:** Elastic File System (EFS) mounted automatically across all subnets. Cron concurrency is managed natively by Moodle, eliminating file-system lock bottlenecks.
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
* Uses `envsubst` to dynamically inject AWS resource endpoints and credentials directly into `config.php` and `sys-test.php`.
* Automatically generates `.ebextensions` (for EFS mounts and PHP tuning), `.platform` (for Nginx overrides), and a GitHub Actions deployment workflow (`.github/workflows/deploy.yml`).
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
3. Modify the static variables at the top of `provision-moodle.sh` (ensure you set `$WWWROOT` to your actual domain).
4. Make the scripts executable:
```bash
chmod +x provision-moodle.sh teardown-moodle.sh verify-aws-billing.sh cloudflare-aws-lb.sh
```
5. Run the provisioning script:
```bash
./provision-moodle.sh
```
6. **Retrieve Credentials:** Once complete, open `github_deploy_keys.json` to get your `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY`. Add these to your GitHub Repository Secrets for CI/CD.

### Phase 2: Secure the Network (Cloudflare)

Once Elastic Beanstalk is fully provisioned and your Load Balancer is active, you must configure Cloudflare to route and secure the traffic.

1. In Cloudflare, add a CNAME record pointing your domain (e.g., `learn.example.com`) to your Elastic Beanstalk environment URL.
2. Ensure the Cloudflare Proxy status is set to **Proxied** (Orange Cloud).
3. Under Cloudflare SSL/TLS settings, set the encryption mode to **Full** or **Full (Strict)**.
4. Run the lockdown script in CloudShell to prevent bypass access to the ALB:
```bash
./cloudflare-aws-lb.sh
```

### Phase 3: Sync Local Git Repo & Deploy

The provisioning script generated several configuration files directly in CloudShell. You must sync these to your local Moodle codebase and push them via GitHub Actions.

1. Download the generated `.ebextensions`, `.platform`, `.github`, `config.php`, and `sys-test.php` files from CloudShell.
2. Place them directly into the root directory of your local Moodle repository.
3. Commit and push the updates to trigger the GitHub Actions deployment:
```bash
git add .
git commit -m "Add AWS EB configuration files and Moodle 5.2 routing"
git push origin main
```
4. Navigate to `https://<YOUR_DOMAIN>/sys-test.php` to verify database, cache, and storage connectivity before initiating the Moodle web installer.

### Phase 4: Testing ALB & Autoscaling

To verify that Elastic Beanstalk scales instances up when CPU utilization exceeds 70%, you can use a Python script to flood the Application Load Balancer with concurrent HTTP requests.

1. Create a file named `load_test.py` on your local machine:
```python
import threading
import requests

URL = "https://<YOUR_DOMAIN>/sys-test.php"

def send_request():
    while True:
        try:
            requests.get(URL, timeout=5)
        except:
            pass

# Spawn 200 concurrent threads to generate CPU load
for i in range(200):
    thread = threading.Thread(target=send_request)
    thread.start()

```
2. Run the script: `python3 load_test.py`
3. Monitor the **Elastic Beanstalk > Events** dashboard. Within 5 minutes, you should see a message stating the ALB has triggered a scale-up event from 2 to 3 instances.

### Phase 5: Essential Moodle CLI Maintenance

Run these commands via AWS Systems Manager (SSM) or CloudShell to perform maintenance without UI timeouts. Always execute as the `webapp` user.

* **Purge Caches:**
```bash
sudo -u webapp php /var/app/current/admin/cli/purge_caches.php
```
* **Run Cron Manually:**
```bash
sudo -u webapp php /var/app/current/admin/cli/cron.php
```
* **Bulk Delete Orphaned Plugins:**
```bash
sudo -u webapp php /var/app/current/admin/cli/uninstall_plugins.php --purge-missing --run
```

### Phase 6: Teardown (Stopping Charges)

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
