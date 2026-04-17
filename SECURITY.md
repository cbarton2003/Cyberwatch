# Security Practices

CyberWatch processes threat intelligence data. The security posture of the platform itself matters as much as the security data it manages.

---

## Secrets Management

All secrets flow through **AWS Secrets Manager**. Nothing sensitive is baked into container images, task definition JSON, or environment variable literals.

### What lives in Secrets Manager

| Secret path | Contents | Rotation |
|-------------|----------|----------|
| `cyberwatch/prod/api-keys` | Comma-separated API keys | Manual (rotate via console or CLI) |
| RDS managed secret | `{ username, password }` | Automatic — RDS rotates every 7 days |
| `cyberwatch/prod/redis-auth` | ElastiCache auth token | Manual |

### How secrets reach containers

The ECS task **execution role** has `secretsmanager:GetSecretValue` permission scoped to only the above ARNs. The ECS agent resolves them at task start and injects them as environment variables. They never appear in CloudWatch logs (Pino redacts `x-api-key` headers before logging).

### Rotating API keys (zero-downtime)

```bash
# 1. Add the new key to the secret (keep the old key too)
aws secretsmanager update-secret \
  --secret-id cyberwatch/prod/api-keys \
  --secret-string "old-key-abc,new-key-xyz"

# 2. Force a new ECS task deployment so containers pick up the new value
aws ecs update-service \
  --cluster cyberwatch-prod \
  --service cyberwatch-api-prod \
  --force-new-deployment

# 3. Migrate all clients to the new key

# 4. Remove the old key
aws secretsmanager update-secret \
  --secret-id cyberwatch/prod/api-keys \
  --secret-string "new-key-xyz"

aws ecs update-service \
  --cluster cyberwatch-prod \
  --service cyberwatch-api-prod \
  --force-new-deployment
```

---

## API Authentication

All routes except `/health` require an `X-API-Key` header. The middleware:
- Checks the key against a `Set<string>` loaded from the `API_KEYS` environment variable at startup
- Logs failed attempts with source IP (not the submitted key value) at `warn` level
- Returns a generic `401 Invalid API key` — no detail that would help enumeration

**Production extension points:**
- Replace the static key set with a database-backed key store to support per-key rate limits, expiry dates, and per-key audit logs
- Add HMAC request signing for high-assurance integrations (EDR agents, automated feeds)
- Integrate with an API gateway (AWS API Gateway or Kong) for centralized key management and DDoS protection in front of the ALB

---

## IAM Least Privilege

### Task Execution Role
Permissions: pull ECR images, write CloudWatch logs, read specific Secrets Manager ARNs. Nothing else.

### Task Role (the app's identity)
By default empty — the application has no AWS permissions. Add only what it actually needs:

```hcl
# Example: allow API to publish to an SNS topic for webhook callbacks
resource "aws_iam_role_policy" "task_sns" {
  name = "cyberwatch-sns-publish"
  role = module.ecs.task_role_arn
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["sns:Publish"]
      Resource = aws_sns_topic.webhooks.arn
    }]
  })
}
```

Explicit deny on IAM actions prevents confused-deputy attacks:

```hcl
resource "aws_iam_role_policy" "task_deny_iam" {
  name = "cyberwatch-deny-iam"
  role = module.ecs.task_role_arn
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Deny"
      Action   = ["iam:*", "sts:AssumeRole"]
      Resource = "*"
    }]
  })
}
```

---

## Container Security

### Non-root user
Both Dockerfiles create and switch to `appuser` in `appgroup`. The process runs as UID ~1000 — kernel exploits that require root fail immediately.

### Read-only root filesystem
ECS task definitions set `readonlyRootFilesystem: true`. The container filesystem is immutable at runtime. Any code path that tries to write to `/` fails with a permission error — malware payloads that drop executables to disk are contained.

### Dropped capabilities
```json
"linuxParameters": {
  "capabilities": { "drop": ["ALL"], "add": [] },
  "initProcessEnabled": true
}
```
No raw sockets, no port binding below 1024, no `ptrace`, no filesystem privilege escalation.

### Image scanning
ECR has `scan_on_push = true`. Every pushed image is scanned for OS and library CVEs. The CI pipeline also runs **Trivy** before push — CRITICAL or HIGH CVEs fail the pipeline before the image ever reaches ECR.

### Verify no secrets in image layers
```bash
# Inspect all layers for accidental secret commits
docker history cyberwatch-api:latest --no-trunc | grep -iE "secret|password|key|token"
# Must return nothing
```

---

## CI/CD Security

### What the pipeline enforces
- **Trivy CVE scan** — scans the built image; CRITICAL/HIGH CVEs = hard fail
- **Gitleaks secret detection** — scans the entire git history on every push
- **SARIF upload** — scan results appear in GitHub Security tab for audit trail
- **SBOM + SLSA provenance** — attached to every image push; confirms the image was built from this exact commit in this exact pipeline

### Branch protection (configure in GitHub Settings → Branches)
- `main` and `staging`: require PR + 1 review + all status checks passing
- No force pushes on `main`
- Require branches to be up to date before merging

### Least-privilege CI credentials
The `cyberwatch-ci` IAM user has `PowerUserAccess` for initial setup. Harden for production:

```bash
# Create a scoped policy — only what CI actually needs
aws iam create-policy \
  --policy-name CyberwatchCIPolicy \
  --policy-document file://infra/iam/ci-policy.json

# Detach broad policy
aws iam detach-user-policy \
  --user-name cyberwatch-ci \
  --policy-arn arn:aws:iam::aws:policy/PowerUserAccess

# Attach scoped policy
aws iam attach-user-policy \
  --user-name cyberwatch-ci \
  --policy-arn arn:aws:iam::aws:policy:CyberwatchCIPolicy
```

The minimal CI permissions needed: `ecr:*` on the two repos, `ecs:UpdateService` + `ecs:RegisterTaskDefinition` on the cluster, `iam:PassRole` for execution/task roles.

---

## Network Security

### Traffic flow
```
Internet → ALB (public, ports 80+443) → TLS terminated
  → HTTP :3000 to ECS API tasks (private subnet)
    → PostgreSQL :5432 to RDS (private subnet, ECS SG only)
    → Redis :6379 to ElastiCache (private subnet, ECS SG only)
```

No resource has inbound access from `0.0.0.0/0` except the ALB.

### Security group matrix

| Resource | Inbound from | Port |
|----------|-------------|------|
| ALB | 0.0.0.0/0 | 443, 80 (redirect only) |
| ECS tasks | ALB security group only | 3000 |
| RDS | ECS task SG only | 5432 |
| Redis | ECS task SG only | 6379 |

### VPC Flow Logs
All traffic metadata is captured to CloudWatch (`/aws/vpc/cyberwatch-prod/flow-logs`) with 90-day retention in prod. This is your first stop when investigating suspicious traffic patterns — you can see source/dest IPs, ports, byte counts, and accept/reject decisions for every flow through the VPC.

---

## Threat Intelligence Data Handling

CyberWatch stores IOC values (IP addresses, domains, file hashes) that may be sensitive in a forensics context. Protect this data:

- **Encryption at rest** — RDS and ElastiCache both use KMS keys (`alias/cyberwatch-prod`) for storage encryption
- **Encryption in transit** — RDS connections require SSL (`DB_SSL=true`), ElastiCache uses TLS (`REDIS_TLS=true`)
- **Access control** — only ECS tasks (via SG rules) can reach RDS or Redis; no public endpoints
- **Log redaction** — Pino redacts `req.headers["x-api-key"]` before writing to CloudWatch; IOC values are not redacted (they're the data, not credentials) but treat CloudWatch access accordingly
- **Retention** — CloudWatch logs retained for 90 days in prod; consider S3 archival for compliance requirements
