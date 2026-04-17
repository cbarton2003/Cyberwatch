# CyberWatch — Threat Intelligence Processing Platform

A production-grade security event ingestion and IOC enrichment platform.
Analysts and automated agents submit security events and indicators of compromise (IOCs)
via the REST API. A background worker enriches each IOC — scoring threats, correlating
events, and flagging high-severity alerts — while the API exposes query endpoints for
dashboards, SIEM integrations, and incident responders.

---

## What CyberWatch Does

```
External source         CyberWatch                         Analysts / SIEM
(EDR, firewall,   ──►  POST /events      ──►  Worker       GET /events?severity=critical
 honeypot, feed)       POST /iocs              enriches     GET /iocs?type=ip&score=8
                       POST /scans             + scores     GET /alerts
                                               + alerts     GET /scans/:id/report
```

**Ingestion flow:**
1. A source (firewall, EDR agent, threat feed parser) submits a security event or IOC via the REST API
2. The API validates, persists to PostgreSQL, and enqueues an enrichment job on Redis
3. The worker picks up the job and runs the enrichment pipeline:
   - Classifies the IOC type (IP, domain, hash, URL)
   - Calculates a threat score (0–10) based on heuristics and metadata
   - Correlates against existing events in the DB
   - Generates an alert if the score exceeds the configured threshold
   - Updates the record with enrichment results and final disposition
4. Responders query the API or receive webhook callbacks when alerts fire

---

## Architecture

```
                          ┌──────────────────────────────────────────────────────┐
                          │                     AWS VPC                          │
                          │                                                      │
  Internet ──► ALB ──────►│  ┌──────────────┐       ┌───────────────┐           │
  (feeds/agents)          │  │  API Service  │──────►│  Redis (ECC)  │           │
                          │  │  (ECS Fargate)│       └──────┬────────┘           │
                          │  └──────┬────────┘              │                   │
                          │         │                 ┌──────▼────────┐          │
                          │         │                 │  Enrichment   │          │
                          │         │                 │  Worker       │          │
                          │         │                 │  (ECS Fargate)│          │
                          │         ▼                 └──────┬────────┘          │
                          │  ┌──────────────┐               │                   │
                          │  │  PostgreSQL  │◄──────────────┘                   │
                          │  │  (RDS)       │  events, iocs, alerts, scans       │
                          │  └──────────────┘                                   │
                          │                                                      │
                          │  Public Subnets:  ALB, NAT GW                       │
                          │  Private Subnets: ECS tasks, RDS, Redis             │
                          └──────────────────────────────────────────────────────┘
```

## Tech Stack

| Layer | Choice | Why |
|-------|--------|-----|
| API | Node.js + Express | Fast async I/O suits high-volume event ingestion |
| Worker | Node.js + BullMQ | Redis-backed queue, retry logic, priority lanes |
| Database | PostgreSQL (RDS) | JSONB for flexible IOC metadata, strong indexing |
| Queue | Redis (ElastiCache) | Sub-ms enqueue latency, BullMQ native |
| Container | Docker + ECR | Immutable builds, scan-on-push |
| IaC | Terraform | Modular, state-managed, env-separated |
| Cloud | AWS ECS Fargate | No node ops, per-task billing, Secrets Manager native |
| CI/CD | GitHub Actions | Trivy CVE scanning, Gitleaks secret detection |

## Repo Structure

```
cyberwatch/
├── services/
│   ├── api/
│   │   ├── src/
│   │   │   ├── routes/
│   │   │   │   ├── events.js       # Security event ingestion & query
│   │   │   │   ├── iocs.js         # IOC submission & lookup
│   │   │   │   ├── alerts.js       # Alert management
│   │   │   │   ├── scans.js        # Bulk scan jobs
│   │   │   │   └── health.js
│   │   │   ├── middleware/
│   │   │   │   ├── errorHandler.js
│   │   │   │   └── apiKey.js       # API key auth middleware
│   │   │   ├── db.js
│   │   │   ├── queue.js
│   │   │   ├── logger.js
│   │   │   └── app.js
│   │   ├── migrations/
│   │   │   └── 001_create_schema.sql
│   │   ├── Dockerfile
│   │   └── package.json
│   └── worker/
│       ├── src/
│       │   ├── processors/
│       │   │   ├── enrichIoc.js    # IOC enrichment pipeline
│       │   │   └── processScan.js  # Bulk scan coordinator
│       │   ├── index.js
│       │   └── logger.js
│       ├── Dockerfile
│       └── package.json
├── infra/terraform/
│   ├── modules/
│   │   ├── vpc/ alb/ ecs/ rds/ elasticache/ ecr/ monitoring/ iam/
│   └── environments/
│       ├── dev/ staging/ prod/
├── .github/workflows/
│   ├── ci.yml
│   └── deploy.yml
├── docker-compose.yml
├── Makefile
├── README.md
├── DEPLOYMENT.md
└── SECURITY.md
```

## Branching Strategy (GitFlow)

```
main       ──────────────────────────────────►  production
staging    ──────────────────────────────────►  staging
develop    ──────────────────────────────────►  dev (auto)
feature/*  ────────── PR → develop
hotfix/*   ────────── PR → main + backmerge to develop
```

**Rules:**
- `feature/*` → PR to `develop` (1 review + CI pass required)
- `develop` auto-deploys to dev on push
- `staging` auto-deploys to staging (manually promoted from develop)
- `main` deploys to prod after manual GitHub Environment approval gate

## Commit Convention

```
feat(api): add bulk IOC submission endpoint
fix(worker): handle malformed IP addresses in enrichment
chore(infra): upgrade RDS to PostgreSQL 16.2
test(worker): add unit tests for threat scoring heuristics
ci: add SARIF upload for Trivy scan results
docs: update IOC type reference in README
```

## Quick Start (Local)

```bash
git clone https://github.com/your-org/cyberwatch
cd cyberwatch

# Start the full stack
make dev

# Run migrations
make migrate

# Submit a test IOC
curl -X POST http://localhost:3000/iocs \
  -H "Content-Type: application/json" \
  -H "X-API-Key: dev-key-local" \
  -d '{"value":"198.51.100.42","type":"ip","source":"honeypot","tags":["scanner"]}'

# Submit a security event
curl -X POST http://localhost:3000/events \
  -H "Content-Type: application/json" \
  -H "X-API-Key: dev-key-local" \
  -d '{"title":"SSH brute force detected","severity":"high","source_ip":"198.51.100.42","category":"brute_force"}'

# Query alerts generated by the worker
curl http://localhost:3000/alerts -H "X-API-Key: dev-key-local"
```

## Common Failure Scenarios

| Symptom | Likely Cause | Fix |
|---------|-------------|-----|
| 401 on all API calls | Missing or wrong X-API-Key header | Check API_KEYS env var is set and matches |
| IOCs stuck in `pending` | Worker crashed or can't reach Redis | Check worker ECS service events + CloudWatch logs |
| High enrichment latency | Worker concurrency too low | Scale up `WORKER_CONCURRENCY` or add more ECS tasks |
| DB connection timeouts | Pool exhausted under load | Increase `DB_POOL_MAX` or scale RDS instance |
| 503 from ALB | ECS tasks failing health checks | Check `/health` endpoint, inspect task stop reason |
| Terraform state lock | Previous apply interrupted | `terraform force-unlock <lock-id>` |
