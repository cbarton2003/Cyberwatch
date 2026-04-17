.PHONY: dev down build test migrate logs clean ecr-login tf-plan tf-apply

ENV ?= dev

# ── Local Development ──────────────────────────────────────────────────────────
dev:
	docker compose up --build

dev-bg:
	docker compose up --build -d

monitoring:
	docker compose --profile monitoring up -d

down:
	docker compose down

clean:
	docker compose down -v --remove-orphans

build:
	docker compose build

# ── Database ───────────────────────────────────────────────────────────────────
migrate:
	docker compose exec api npm run migrate

migrate-down:
	docker compose exec api npm run migrate:down

psql:
	docker compose exec postgres psql -U cyberwatch -d cyberwatch

# ── Testing ────────────────────────────────────────────────────────────────────
test:
	cd services/api && npm test

test-watch:
	cd services/api && npm test -- --watch

# ── Logs ───────────────────────────────────────────────────────────────────────
logs:
	docker compose logs -f

logs-api:
	docker compose logs -f api

logs-worker:
	docker compose logs -f worker

# ── Terraform ──────────────────────────────────────────────────────────────────
tf-init:
	cd infra/terraform/environments/$(ENV) && terraform init

tf-plan:
	cd infra/terraform/environments/$(ENV) && terraform plan

tf-apply:
	cd infra/terraform/environments/$(ENV) && terraform apply

tf-destroy:
	cd infra/terraform/environments/$(ENV) && terraform destroy

tf-fmt:
	terraform fmt -recursive infra/terraform/

# ── AWS ────────────────────────────────────────────────────────────────────────
AWS_REGION  ?= eu-west-1
AWS_ACCOUNT ?= $(shell aws sts get-caller-identity --query Account --output text)
ECR          = $(AWS_ACCOUNT).dkr.ecr.$(AWS_REGION).amazonaws.com

ecr-login:
	aws ecr get-login-password --region $(AWS_REGION) | \
	docker login --username AWS --password-stdin $(ECR)

ecr-create:
	aws ecr create-repository --repository-name cyberwatch-api    --region $(AWS_REGION) || true
	aws ecr create-repository --repository-name cyberwatch-worker --region $(AWS_REGION) || true

# ── Quick API tests ────────────────────────────────────────────────────────────
KEY ?= dev-key-local

submit-ioc:
	curl -s -X POST http://localhost:3000/iocs \
	  -H "Content-Type: application/json" \
	  -H "X-API-Key: $(KEY)" \
	  -d '{"value":"198.51.100.42","type":"ip","source":"honeypot","severity":"high","tags":["scanner"]}' | jq .

submit-event:
	curl -s -X POST http://localhost:3000/events \
	  -H "Content-Type: application/json" \
	  -H "X-API-Key: $(KEY)" \
	  -d '{"title":"SSH brute force","severity":"high","category":"brute_force","source_ip":"198.51.100.42"}' | jq .

list-iocs:
	curl -s http://localhost:3000/iocs -H "X-API-Key: $(KEY)" | jq .

list-alerts:
	curl -s http://localhost:3000/alerts -H "X-API-Key: $(KEY)" | jq .

check-health:
	curl -s http://localhost:3000/health | jq .

# ── Dashboard UI ───────────────────────────────────────────────────────────────
ui:
	@echo "Opening dashboard at http://localhost:8080"
	@echo "API: http://localhost:3000  |  Key: dev-key-local"
	@command -v python3 >/dev/null && python3 -m http.server 8080 --directory dashboard || npx serve dashboard -l 8080

help:
	@grep -E '^[a-zA-Z_-]+:' Makefile | awk -F: '{print $$1}' | sort
