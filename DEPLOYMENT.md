# CyberWatch — Deployment Guide

Step-by-step instructions from a blank AWS account to a running CyberWatch deployment.

---

## Prerequisites

| Tool | Version | Install |
|------|---------|---------|
| AWS CLI | >= 2.x | `brew install awscli` |
| Terraform | >= 1.6 | `brew install terraform` |
| Docker | >= 24 | [docker.com](https://docker.com) |
| Node.js | 20 LTS | `brew install node` |
| jq | any | `brew install jq` |

```bash
# Verify all tools
aws --version && terraform --version && docker --version && node --version && jq --version
```

You will also need:
- An **AWS account** with billing enabled
- A **GitHub repository** forked or cloned from the project
- A **domain name** with a hosted zone in Route53 (or you can skip DNS and use the raw ALB hostname)

---

## Phase 1 — AWS Account Bootstrap

### 1.1 Configure your AWS CLI

```bash
aws configure
# AWS Access Key ID:     <your root or admin key>
# AWS Secret Access Key: <your secret>
# Default region:        eu-west-1
# Default output format: json

# Confirm identity
aws sts get-caller-identity
```

### 1.2 Create a dedicated CI/CD IAM user

```bash
# Create the CI user
aws iam create-user --user-name cyberwatch-ci

# Grant permissions (tighten this policy for hardened environments)
aws iam attach-user-policy \
  --user-name cyberwatch-ci \
  --policy-arn arn:aws:iam::aws:policy/PowerUserAccess

# Create access keys — save these for GitHub Secrets
aws iam create-access-key --user-name cyberwatch-ci
# → Copy AccessKeyId and SecretAccessKey now; you cannot retrieve the secret again
```

### 1.3 Bootstrap Terraform remote state

```bash
cd cyberwatch/infra

# Creates S3 bucket (versioned + encrypted) and DynamoDB lock table per environment
ENV=dev     bash bootstrap.sh
ENV=staging bash bootstrap.sh
ENV=prod    bash bootstrap.sh
```

Each run prints the bucket name and writes a `backend.tf` into the matching environment folder.

### 1.4 Create ECR repositories

```bash
REGION=eu-west-1

aws ecr create-repository --repository-name cyberwatch-api    --region $REGION
aws ecr create-repository --repository-name cyberwatch-worker --region $REGION

# Lifecycle: expire untagged images after 1 day, keep last 15 sha-tagged
for REPO in cyberwatch-api cyberwatch-worker; do
  aws ecr put-lifecycle-policy \
    --repository-name $REPO \
    --lifecycle-policy-text '{
      "rules":[
        {"rulePriority":1,"selection":{"tagStatus":"untagged","countType":"sinceImagePushed","countUnit":"days","countNumber":1},"action":{"type":"expire"}},
        {"rulePriority":2,"selection":{"tagStatus":"tagged","tagPrefixList":["sha-"],"countType":"imageCountMoreThan","countNumber":15},"action":{"type":"expire"}}
      ]}'
done
```

### 1.5 Request an ACM TLS certificate

```bash
aws acm request-certificate \
  --domain-name "api.yourdomain.com" \
  --validation-method DNS \
  --region eu-west-1
```

Go to the **ACM console → Certificates → your cert → Create records in Route 53**.
Wait until status shows **Issued** (2–5 minutes). Copy the certificate ARN.

---

## Phase 2 — GitHub Configuration

### 2.1 Add repository secrets

**Settings → Secrets and variables → Actions → New repository secret:**

| Secret | Value |
|--------|-------|
| `AWS_ACCOUNT_ID` | `aws sts get-caller-identity --query Account --output text` |
| `AWS_ACCESS_KEY_ID` | CI user key from step 1.2 |
| `AWS_SECRET_ACCESS_KEY` | CI user secret from step 1.2 |
| `SLACK_WEBHOOK_URL` | Slack incoming webhook URL (optional) |
| `CODECOV_TOKEN` | From codecov.io (optional) |

### 2.2 Create deployment environments

**Settings → Environments** — create `dev`, `staging`, `prod`.

For **prod**, add at least one **Required reviewer**. This pauses the deploy pipeline and requires a human to click **Approve** in the GitHub Actions UI before the production deploy runs.

---

## Phase 3 — Provision Infrastructure

Start with `dev`. Repeat identically for `staging` and `prod`.

### 3.1 Create terraform.tfvars

```bash
cd cyberwatch/infra/terraform/environments/dev
```

Create `terraform.tfvars` — **this file is gitignored, never commit it**:

```hcl
# dev environment
certificate_arn       = "arn:aws:acm:eu-west-1:123456789012:certificate/YOUR-CERT-ID"
redis_auth_token      = "a-long-random-secret-at-least-16-chars"
api_image_tag         = "latest"
worker_image_tag      = "latest"
api_keys              = "your-dev-api-key-1,your-dev-api-key-2"
alert_email           = "security@yourorg.com"
alert_score_threshold = 7.0
```

For **prod**, add domain variables too:

```hcl
# additional prod variables
domain_name      = "api.yourdomain.com"
hosted_zone_name = "yourdomain.com"
```

### 3.2 Initialise and apply

```bash
terraform init
terraform plan    # Review every resource. Nothing is created yet.
terraform apply   # Type 'yes' to confirm. Takes ~12 minutes first run.
```

Resources created per environment: VPC + subnets + NAT GW + IGW + route tables + VPC flow logs + ALB + HTTPS/HTTP listeners + target group + ECS cluster + API service + worker service + task definitions + RDS PostgreSQL 16 + ElastiCache Redis + all security groups + IAM execution and task roles + CloudWatch log groups + metric filters + alarms + SNS alert topic.

### 3.3 Note the outputs

```bash
terraform output alb_dns     # e.g. cyberwatch-dev-alb-123456.eu-west-1.elb.amazonaws.com
terraform output ecs_cluster # cyberwatch-dev
```

---

## Phase 4 — Build and Push First Images

### 4.1 Authenticate to ECR

```bash
# Use the Makefile shortcut
make ecr-login

# Or manually
ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
aws ecr get-login-password --region eu-west-1 | \
  docker login --username AWS --password-stdin \
  $ACCOUNT.dkr.ecr.eu-west-1.amazonaws.com
```

### 4.2 Build and push

```bash
ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
REGION=eu-west-1
ECR="$ACCOUNT.dkr.ecr.$REGION.amazonaws.com"

# Build production images
docker build -t cyberwatch-api:v1    ./services/api    --target production
docker build -t cyberwatch-worker:v1 ./services/worker --target production

# Tag
docker tag cyberwatch-api:v1    $ECR/cyberwatch-api:latest
docker tag cyberwatch-worker:v1 $ECR/cyberwatch-worker:latest

# Push
docker push $ECR/cyberwatch-api:latest
docker push $ECR/cyberwatch-worker:latest
```

---

## Phase 5 — Run Database Migrations

RDS is in a private subnet. Run migrations via a one-off ECS task:

```bash
CLUSTER=$(cd infra/terraform/environments/dev && terraform output -raw ecs_cluster)
SUBNET=$(aws ec2 describe-subnets \
  --filters "Name=tag:Tier,Values=private" "Name=tag:Environment,Values=dev" \
  --query "Subnets[0].SubnetId" --output text)
SG=$(aws ec2 describe-security-groups \
  --filters "Name=group-name,Values=cyberwatch-dev-ecs-tasks-sg" \
  --query "SecurityGroups[0].GroupId" --output text)

# Run schema migration as a one-off Fargate task
aws ecs run-task \
  --cluster $CLUSTER \
  --task-definition cyberwatch-api-dev \
  --launch-type FARGATE \
  --overrides '{"containerOverrides":[{"name":"api","command":["node","-e","require(\"./migrations/run\")"]}]}' \
  --network-configuration "awsvpcConfiguration={subnets=[$SUBNET],securityGroups=[$SG],assignPublicIp=DISABLED}"

# Or apply the SQL directly if you have a bastion/VPN
# psql -h <rds-endpoint> -U cyberwatch -d cyberwatch -f services/api/migrations/001_create_schema.sql
```

---

## Phase 6 — Verify the Deployment

```bash
ALB=$(cd infra/terraform/environments/dev && terraform output -raw alb_dns)
API_KEY="your-dev-api-key-1"

# Health check (no auth required)
curl https://$ALB/health
# Expected: {"status":"ok","services":{"postgres":"ok","redis":"ok"}}

# Submit an IP IOC for enrichment
curl -s -X POST https://$ALB/iocs \
  -H "Content-Type: application/json" \
  -H "X-API-Key: $API_KEY" \
  -d '{"value":"198.51.100.42","type":"ip","source":"honeypot","tags":["scanner","ssh"]}' | jq .

# Check enrichment status (poll until enrichment_status = "enriched")
IOC_ID=$(curl -s https://$ALB/iocs -H "X-API-Key: $API_KEY" | jq -r '.data[0].id')
curl -s https://$ALB/iocs/$IOC_ID -H "X-API-Key: $API_KEY" | jq '.data | {value, threat_score, disposition, enrichment_status}'

# Check alerts generated by high-scoring IOCs
curl -s https://$ALB/alerts -H "X-API-Key: $API_KEY" | jq '.data[] | {ioc_value, threat_score, acknowledged}'

# Ingest a security event
curl -s -X POST https://$ALB/events \
  -H "Content-Type: application/json" \
  -H "X-API-Key: $API_KEY" \
  -d '{"title":"SSH brute force from 198.51.100.42","severity":"high","category":"brute_force","source_ip":"198.51.100.42"}' | jq .

# Submit a domain IOC (DGA-like → should score high)
curl -s -X POST https://$ALB/iocs \
  -H "Content-Type: application/json" \
  -H "X-API-Key: $API_KEY" \
  -d '{"value":"xk7f2q9a.xyz","type":"domain","source":"dns_log"}' | jq '.data | {value, threat_score, disposition}'

# Verify ECS services are stable
aws ecs describe-services \
  --cluster cyberwatch-dev \
  --services cyberwatch-api-dev cyberwatch-worker-dev \
  --query 'services[*].{name:serviceName,running:runningCount,desired:desiredCount,status:status}'
```

---

## Phase 7 — CI/CD Pipeline

From this point, all deployments are automated by GitHub Actions.

### Push to develop → auto-deploy to dev

```bash
git checkout develop
git add .
git commit -m "feat: initial cyberwatch deployment"
git push origin develop

# Watch at: github.com/your-org/cyberwatch/actions
# Pipeline: test → build → trivy scan → gitleaks → push to ECR → deploy to ECS dev
```

### Promote to staging

```bash
git checkout staging
git merge develop
git push origin staging
# Auto-deploys to staging environment
```

### Promote to production

```bash
git checkout main
git merge staging
git push origin main
# CI runs, reaches "Deploy to prod", pauses for approval
# GitHub → Actions → the running workflow → "Review deployments" → Approve
```

---

## Phase 8 — Optional DNS Setup

Terraform handles DNS automatically in prod via `aws_route53_record`. After `terraform apply` on prod, the API is live at `https://api.yourdomain.com`.

For dev/staging without Terraform DNS management, add a CNAME manually:

```
api-dev.yourdomain.com → CNAME → cyberwatch-dev-alb-xxx.eu-west-1.elb.amazonaws.com
```

---

## Rollback

```bash
# Find the previous stable task definition revision
aws ecs list-task-definitions \
  --family-prefix cyberwatch-api-prod \
  --sort DESC \
  --query 'taskDefinitionArns[:5]'

# Force-rollback both services to previous revision
aws ecs update-service \
  --cluster cyberwatch-prod \
  --service cyberwatch-api-prod \
  --task-definition cyberwatch-api-prod:42 \
  --force-new-deployment

aws ecs update-service \
  --cluster cyberwatch-prod \
  --service cyberwatch-worker-prod \
  --task-definition cyberwatch-worker-prod:42 \
  --force-new-deployment

# Wait for stability
aws ecs wait services-stable \
  --cluster cyberwatch-prod \
  --services cyberwatch-api-prod cyberwatch-worker-prod

echo "Rollback complete"
```

---

## Log Access

```bash
# Live tail API logs
aws logs tail /ecs/cyberwatch-prod/api --follow

# Live tail worker (enrichment) logs
aws logs tail /ecs/cyberwatch-prod/worker --follow

# Query for fired alerts in the last hour
aws logs filter-log-events \
  --log-group-name /ecs/cyberwatch-prod/worker \
  --start-time $(date -d '1 hour ago' +%s000) \
  --filter-pattern '"Alert fired"'

# Query for API errors
aws logs filter-log-events \
  --log-group-name /ecs/cyberwatch-prod/api \
  --start-time $(date -d '1 hour ago' +%s000) \
  --filter-pattern '{ $.level = "error" }'
```

---

## Local Development

No AWS account needed for local development.

```bash
cd cyberwatch

# Copy env file
cp services/api/.env.example services/api/.env

# Start everything (Postgres + Redis + API + Worker)
make dev

# Run migrations
make migrate

# Submit a test IOC
make curl-ioc

# Submit a test security event
make curl-event

# Open Bull Board queue monitor at http://localhost:3001
make monitoring
```

---

## Quick Reference

| Command | What it does |
|---------|-------------|
| `make dev` | Start full local stack |
| `make test` | Run integration test suite |
| `make migrate` | Apply DB migrations |
| `make logs-api` | Tail API container logs |
| `make logs-worker` | Tail worker container logs |
| `make curl-ioc` | Submit a test IP IOC locally |
| `make curl-event` | Submit a test security event locally |
| `make ecr-login` | Authenticate Docker to ECR |
| `make tf-plan ENV=prod` | Preview production infrastructure changes |
| `make tf-apply ENV=dev` | Apply dev infrastructure changes |
