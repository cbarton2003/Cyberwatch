resource "aws_security_group" "redis" {
  name        = "${var.name}-redis-sg"
  description = "Redis: inbound from ECS tasks only"
  vpc_id      = var.vpc_id
  ingress {
    from_port       = 6379; to_port = 6379; protocol = "tcp"
    security_groups = var.allowed_security_group_ids
    description     = "Redis from ECS tasks"
  }
  tags = merge(var.tags, { Name = "${var.name}-redis-sg" })
}

resource "aws_elasticache_subnet_group" "main" {
  name       = "${var.name}-redis-subnet-group"
  subnet_ids = var.private_subnet_ids
  tags       = var.tags
}

resource "aws_elasticache_parameter_group" "main" {
  name   = "${var.name}-redis7"
  family = "redis7"
  parameter { name = "maxmemory-policy"; value = "noeviction" }
  tags = var.tags
}

resource "aws_elasticache_replication_group" "main" {
  replication_group_id       = "${var.name}-redis"
  description                = "Redis queue for ${var.name} enrichment worker"
  node_type                  = var.node_type
  num_cache_clusters         = var.multi_az ? 2 : 1
  port                       = 6379
  subnet_group_name          = aws_elasticache_subnet_group.main.name
  security_group_ids         = [aws_security_group.redis.id]
  parameter_group_name       = aws_elasticache_parameter_group.main.name
  transit_encryption_enabled = true
  at_rest_encryption_enabled = true
  kms_key_id                 = var.kms_key_arn
  auth_token                 = var.auth_token
  automatic_failover_enabled = var.multi_az
  multi_az_enabled           = var.multi_az
  snapshot_retention_limit   = var.snapshot_retention_days
  snapshot_window            = "03:00-04:00"
  maintenance_window         = "Mon:04:00-Mon:05:00"
  apply_immediately          = false
  auto_minor_version_upgrade = true
  tags                       = merge(var.tags, { Name = "${var.name}-redis" })
}

variable "name" { type = string }
variable "vpc_id" { type = string }
variable "private_subnet_ids" { type = list(string) }
variable "allowed_security_group_ids" { type = list(string) }
variable "node_type" { type = string; default = "cache.t4g.micro" }
variable "multi_az" { type = bool; default = false }
variable "auth_token" { type = string; sensitive = true }
variable "kms_key_arn" { type = string; default = null }
variable "snapshot_retention_days" { type = number; default = 1 }
variable "tags" { type = map(string); default = {} }

output "primary_endpoint"  { value = aws_elasticache_replication_group.main.primary_endpoint_address }
output "security_group_id" { value = aws_security_group.redis.id }
