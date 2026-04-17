resource "aws_db_subnet_group" "main" {
  name       = "${var.name}-rds-subnet-group"
  subnet_ids = var.private_subnet_ids
  tags       = merge(var.tags, { Name = "${var.name}-rds-subnet-group" })
}

resource "aws_db_parameter_group" "main" {
  name   = "${var.name}-pg16"
  family = "postgres16"
  parameter { name = "log_connections";             value = "1" }
  parameter { name = "log_disconnections";          value = "1" }
  parameter { name = "log_min_duration_statement";  value = "1000" }
  parameter { name = "shared_preload_libraries";    value = "pg_stat_statements" }
  parameter { name = "pg_stat_statements.track";    value = "all" }
  tags = var.tags
  lifecycle { create_before_destroy = true }
}

resource "aws_security_group" "rds" {
  name        = "${var.name}-rds-sg"
  description = "RDS: inbound Postgres from ECS tasks only"
  vpc_id      = var.vpc_id
  ingress {
    from_port       = 5432; to_port = 5432; protocol = "tcp"
    security_groups = var.allowed_security_group_ids
    description     = "Postgres from ECS tasks"
  }
  tags = merge(var.tags, { Name = "${var.name}-rds-sg" })
}

resource "aws_iam_role" "rds_monitoring" {
  name = "${var.name}-rds-monitoring-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{ Effect = "Allow"; Principal = { Service = "monitoring.rds.amazonaws.com" }; Action = "sts:AssumeRole" }]
  })
  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "rds_monitoring" {
  role       = aws_iam_role.rds_monitoring.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonRDSEnhancedMonitoringRole"
}

resource "aws_db_instance" "main" {
  identifier                          = "${var.name}-postgres"
  engine                              = "postgres"
  engine_version                      = "16.1"
  instance_class                      = var.instance_class
  db_name                             = var.db_name
  username                            = var.db_username
  manage_master_user_password         = true
  db_subnet_group_name                = aws_db_subnet_group.main.name
  vpc_security_group_ids              = [aws_security_group.rds.id]
  parameter_group_name                = aws_db_parameter_group.main.name
  allocated_storage                   = var.allocated_storage
  max_allocated_storage               = var.max_allocated_storage
  storage_type                        = "gp3"
  storage_encrypted                   = true
  kms_key_id                          = var.kms_key_arn
  multi_az                            = var.multi_az
  publicly_accessible                 = false
  deletion_protection                 = var.deletion_protection
  skip_final_snapshot                 = !var.deletion_protection
  final_snapshot_identifier           = var.deletion_protection ? "${var.name}-final-snapshot" : null
  backup_retention_period             = var.backup_retention_days
  backup_window                       = "03:00-04:00"
  maintenance_window                  = "Mon:04:00-Mon:05:00"
  monitoring_interval                 = 60
  monitoring_role_arn                 = aws_iam_role.rds_monitoring.arn
  performance_insights_enabled        = true
  performance_insights_retention_period = var.multi_az ? 731 : 7
  enabled_cloudwatch_logs_exports     = ["postgresql", "upgrade"]
  auto_minor_version_upgrade          = true
  copy_tags_to_snapshot               = true
  tags = merge(var.tags, { Name = "${var.name}-postgres" })
}
