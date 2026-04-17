terraform {
  required_version = ">= 1.6"
  required_providers {
    aws = { source = "hashicorp/aws"; version = "~> 5.30" }
  }
  backend "s3" {
    bucket         = "cyberwatch-terraform-state-prod"
    key            = "prod/terraform.tfstate"
    region         = "eu-west-1"
    encrypt        = true
    dynamodb_table = "cyberwatch-terraform-locks"
  }
}

provider "aws" {
  region = var.aws_region
  default_tags {
    tags = { Project = "cyberwatch"; Environment = "prod"; ManagedBy = "terraform" }
  }
}

data "aws_caller_identity" "current" {}

data "aws_acm_certificate" "main" {
  domain = var.domain_name; statuses = ["ISSUED"]; most_recent = true
}

resource "aws_kms_key" "main" {
  description             = "CyberWatch prod encryption key"
  deletion_window_in_days = 30
  enable_key_rotation     = true
  tags                    = { Name = "cyberwatch-prod-key" }
}

resource "aws_kms_alias" "main" {
  name          = "alias/cyberwatch-prod"
  target_key_id = aws_kms_key.main.key_id
}

# API Keys stored as a Secrets Manager secret so they can be rotated
resource "aws_secretsmanager_secret" "api_keys" {
  name        = "cyberwatch/prod/api-keys"
  description = "Comma-separated API keys for CyberWatch prod"
  kms_key_id  = aws_kms_key.main.arn
  tags        = { Environment = "prod" }
}

resource "aws_secretsmanager_secret_version" "api_keys" {
  secret_id     = aws_secretsmanager_secret.api_keys.id
  secret_string = var.api_keys
}

module "vpc" {
  source                  = "../../modules/vpc"
  name                    = "cyberwatch-prod"
  vpc_cidr                = "10.0.0.0/16"
  az_count                = 2
  flow_log_retention_days = 90
  tags                    = { Environment = "prod" }
}

module "alb" {
  source                     = "../../modules/alb"
  name                       = "cyberwatch-prod"
  vpc_id                     = module.vpc.vpc_id
  public_subnet_ids          = module.vpc.public_subnet_ids
  certificate_arn            = data.aws_acm_certificate.main.arn
  enable_deletion_protection = true
  tags                       = { Environment = "prod" }
}

module "rds" {
  source                     = "../../modules/rds"
  name                       = "cyberwatch-prod"
  vpc_id                     = module.vpc.vpc_id
  private_subnet_ids         = module.vpc.private_subnet_ids
  allowed_security_group_ids = [module.ecs.task_security_group_id]
  instance_class             = "db.t3.small"
  allocated_storage          = 50
  max_allocated_storage      = 1000
  multi_az                   = true
  deletion_protection        = true
  backup_retention_days      = 14
  kms_key_arn                = aws_kms_key.main.arn
  tags                       = { Environment = "prod" }
}

module "redis" {
  source                     = "../../modules/elasticache"
  name                       = "cyberwatch-prod"
  vpc_id                     = module.vpc.vpc_id
  private_subnet_ids         = module.vpc.private_subnet_ids
  allowed_security_group_ids = [module.ecs.task_security_group_id]
  node_type                  = "cache.t4g.small"
  multi_az                   = true
  auth_token                 = var.redis_auth_token
  kms_key_arn                = aws_kms_key.main.arn
  snapshot_retention_days    = 7
  tags                       = { Environment = "prod" }
}

module "ecs" {
  source      = "../../modules/ecs"
  name        = "cyberwatch-prod"
  environment = "prod"
  aws_region  = var.aws_region

  vpc_id             = module.vpc.vpc_id
  private_subnet_ids = module.vpc.private_subnet_ids

  alb_security_group_id   = module.alb.alb_sg_id
  target_group_arn        = module.alb.target_group_arn
  alb_arn_suffix          = module.alb.alb_arn_suffix
  target_group_arn_suffix = module.alb.target_group_arn_suffix

  api_image    = "${data.aws_caller_identity.current.account_id}.dkr.ecr.${var.aws_region}.amazonaws.com/cyberwatch-api:${var.api_image_tag}"
  worker_image = "${data.aws_caller_identity.current.account_id}.dkr.ecr.${var.aws_region}.amazonaws.com/cyberwatch-worker:${var.worker_image_tag}"

  db_host             = module.rds.address
  db_name             = "cyberwatch"
  db_secret_arn       = module.rds.master_user_secret_arn
  api_keys_secret_arn = aws_secretsmanager_secret.api_keys.arn
  redis_host          = module.redis.primary_endpoint
  secrets_arns        = [module.rds.master_user_secret_arn, aws_secretsmanager_secret.api_keys.arn]

  alert_score_threshold = var.alert_score_threshold

  api_cpu           = 512;  api_memory        = 1024
  api_desired_count = 2;    api_min_count     = 2;   api_max_count     = 20
  worker_cpu        = 512;  worker_memory     = 1024
  worker_desired_count = 2; worker_concurrency = 10
  log_retention_days = 90

  tags = { Environment = "prod" }
}

module "monitoring" {
  source              = "../../modules/monitoring"
  name                = "cyberwatch-prod"
  environment         = "prod"
  cluster_name        = module.ecs.cluster_name
  api_service_name    = module.ecs.api_service_name
  worker_service_name = module.ecs.worker_service_name
  alb_arn_suffix      = module.alb.alb_arn_suffix
  rds_identifier      = "cyberwatch-prod-postgres"
  alert_email         = var.alert_email
  tags                = { Environment = "prod" }
}

data "aws_route53_zone" "main" {
  name = var.hosted_zone_name; private_zone = false
}

resource "aws_route53_record" "api" {
  zone_id = data.aws_route53_zone.main.zone_id
  name    = "api.${var.domain_name}"
  type    = "A"
  alias {
    name                   = module.alb.alb_dns_name
    zone_id                = module.alb.alb_zone_id
    evaluate_target_health = true
  }
}

variable "aws_region" { type = string; default = "eu-west-1" }
variable "domain_name" { type = string }
variable "hosted_zone_name" { type = string }
variable "redis_auth_token" { type = string; sensitive = true }
variable "api_image_tag" { type = string }
variable "worker_image_tag" { type = string }
variable "api_keys" { type = string; sensitive = true }
variable "alert_email" { type = string }
variable "alert_score_threshold" { type = number; default = 7.0 }

output "api_url"     { value = "https://api.${var.domain_name}" }
output "alb_dns"     { value = module.alb.alb_dns_name }
output "ecs_cluster" { value = module.ecs.cluster_name }
