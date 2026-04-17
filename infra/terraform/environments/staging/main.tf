terraform {
  required_version = ">= 1.6"
  required_providers {
    aws = { source = "hashicorp/aws"; version = "~> 5.30" }
  }
  backend "s3" {
    bucket         = "cyberwatch-terraform-state-staging"
    key            = "dev/terraform.tfstate"
    region         = "eu-west-1"
    encrypt        = true
    dynamodb_table = "cyberwatch-terraform-locks"
  }
}

provider "aws" {
  region = "eu-west-1"
  default_tags {
    tags = { Project = "cyberwatch"; Environment = "staging"; ManagedBy = "terraform" }
  }
}

data "aws_caller_identity" "current" {}

resource "aws_secretsmanager_secret" "api_keys" {
  name        = "cyberwatch/dev/api-keys"
  description = "API keys for CyberWatch dev"
  tags        = { Environment = "staging" }
}
resource "aws_secretsmanager_secret_version" "api_keys" {
  secret_id     = aws_secretsmanager_secret.api_keys.id
  secret_string = var.api_keys
}

module "vpc" {
  source   = "../../modules/vpc"
  name     = "cyberwatch-staging"
  vpc_cidr = "10.2.0.0/16"
  az_count = 2
  tags     = { Environment = "staging" }
}

module "alb" {
  source            = "../../modules/alb"
  name              = "cyberwatch-staging"
  vpc_id            = module.vpc.vpc_id
  public_subnet_ids = module.vpc.public_subnet_ids
  certificate_arn   = var.certificate_arn
  tags              = { Environment = "staging" }
}

module "rds" {
  source                     = "../../modules/rds"
  name                       = "cyberwatch-staging"
  vpc_id                     = module.vpc.vpc_id
  private_subnet_ids         = module.vpc.private_subnet_ids
  allowed_security_group_ids = [module.ecs.task_security_group_id]
  instance_class             = "db.t3.micro"
  multi_az                   = false
  deletion_protection        = false
  backup_retention_days      = 1
  tags                       = { Environment = "staging" }
}

module "redis" {
  source                     = "../../modules/elasticache"
  name                       = "cyberwatch-staging"
  vpc_id                     = module.vpc.vpc_id
  private_subnet_ids         = module.vpc.private_subnet_ids
  allowed_security_group_ids = [module.ecs.task_security_group_id]
  node_type                  = "cache.t4g.micro"
  multi_az                   = false
  auth_token                 = var.redis_auth_token
  tags                       = { Environment = "staging" }
}

module "ecs" {
  source      = "../../modules/ecs"
  name        = "cyberwatch-staging"
  environment = "staging"
  aws_region  = "eu-west-1"

  vpc_id             = module.vpc.vpc_id
  private_subnet_ids = module.vpc.private_subnet_ids

  alb_security_group_id   = module.alb.alb_sg_id
  target_group_arn        = module.alb.target_group_arn
  alb_arn_suffix          = module.alb.alb_arn_suffix
  target_group_arn_suffix = module.alb.target_group_arn_suffix

  api_image    = "${data.aws_caller_identity.current.account_id}.dkr.ecr.eu-west-1.amazonaws.com/cyberwatch-api:${var.api_image_tag}"
  worker_image = "${data.aws_caller_identity.current.account_id}.dkr.ecr.eu-west-1.amazonaws.com/cyberwatch-worker:${var.worker_image_tag}"

  db_host             = module.rds.address
  db_name             = "cyberwatch"
  db_secret_arn       = module.rds.master_user_secret_arn
  api_keys_secret_arn = aws_secretsmanager_secret.api_keys.arn
  redis_host          = module.redis.primary_endpoint
  secrets_arns        = [module.rds.master_user_secret_arn, aws_secretsmanager_secret.api_keys.arn]

  api_cpu = 256; api_memory = 512; api_desired_count = 1
  api_min_count = 1; api_max_count = 3
  worker_cpu = 256; worker_memory = 512
  worker_desired_count = 1; worker_concurrency = 3
  log_retention_days = 7
  tags = { Environment = "staging" }
}

variable "certificate_arn" { type = string }
variable "redis_auth_token" { type = string; sensitive = true }
variable "api_keys" { type = string; sensitive = true }
variable "api_image_tag" { type = string; default = "develop" }
variable "worker_image_tag" { type = string; default = "develop" }

output "alb_dns" { value = module.alb.alb_dns_name }
output "ecs_cluster" { value = module.ecs.cluster_name }
