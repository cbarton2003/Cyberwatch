resource "aws_ecs_cluster" "main" {
  name = var.name
  setting { name = "containerInsights"; value = "enabled" }
  tags = var.tags
}

resource "aws_ecs_cluster_capacity_providers" "main" {
  cluster_name       = aws_ecs_cluster.main.name
  capacity_providers = ["FARGATE", "FARGATE_SPOT"]
  default_capacity_provider_strategy {
    capacity_provider = "FARGATE"; weight = 1; base = 1
  }
}

resource "aws_cloudwatch_log_group" "api" {
  name              = "/ecs/${var.name}/api"
  retention_in_days = var.log_retention_days
  tags              = var.tags
}

resource "aws_cloudwatch_log_group" "worker" {
  name              = "/ecs/${var.name}/worker"
  retention_in_days = var.log_retention_days
  tags              = var.tags
}

resource "aws_security_group" "ecs_tasks" {
  name        = "${var.name}-ecs-tasks-sg"
  description = "ECS tasks: inbound from ALB only"
  vpc_id      = var.vpc_id
  ingress {
    from_port       = var.api_port; to_port = var.api_port; protocol = "tcp"
    security_groups = [var.alb_security_group_id]
    description     = "API port from ALB"
  }
  egress { from_port = 0; to_port = 0; protocol = "-1"; cidr_blocks = ["0.0.0.0/0"]; description = "All outbound" }
  tags = merge(var.tags, { Name = "${var.name}-ecs-tasks-sg" })
}

data "aws_caller_identity" "current" {}

resource "aws_iam_role" "execution" {
  name = "${var.name}-ecs-execution-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{ Effect = "Allow"; Principal = { Service = "ecs-tasks.amazonaws.com" }; Action = "sts:AssumeRole" }]
  })
  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "execution_managed" {
  role       = aws_iam_role.execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_iam_role_policy" "execution_secrets" {
  name = "${var.name}-execution-secrets"
  role = aws_iam_role.execution.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{ Effect = "Allow"; Action = ["secretsmanager:GetSecretValue","kms:Decrypt"]; Resource = var.secrets_arns }]
  })
}

resource "aws_iam_role" "task" {
  name = "${var.name}-ecs-task-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"; Principal = { Service = "ecs-tasks.amazonaws.com" }; Action = "sts:AssumeRole"
      Condition = { StringEquals = { "aws:SourceAccount" = data.aws_caller_identity.current.account_id } }
    }]
  })
  tags = var.tags
}

resource "aws_ecs_task_definition" "api" {
  family                   = "${var.name}-api"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.api_cpu
  memory                   = var.api_memory
  execution_role_arn       = aws_iam_role.execution.arn
  task_role_arn            = aws_iam_role.task.arn

  container_definitions = jsonencode([{
    name      = "api"
    image     = var.api_image
    essential = true
    portMappings = [{ containerPort = var.api_port; protocol = "tcp" }]
    environment = [
      { name = "NODE_ENV";                value = var.environment },
      { name = "PORT";                    value = tostring(var.api_port) },
      { name = "DB_HOST";                 value = var.db_host },
      { name = "DB_PORT";                 value = "5432" },
      { name = "DB_NAME";                 value = var.db_name },
      { name = "REDIS_HOST";              value = var.redis_host },
      { name = "REDIS_PORT";              value = "6379" },
      { name = "REDIS_TLS";               value = var.environment == "prod" ? "true" : "false" },
      { name = "DB_SSL";                  value = "true" },
      { name = "LOG_LEVEL";               value = var.environment == "prod" ? "info" : "debug" },
      { name = "SERVICE_NAME";            value = "cyberwatch-api" },
      { name = "ALERT_SCORE_THRESHOLD";   value = tostring(var.alert_score_threshold) },
      { name = "RATE_LIMIT_MAX";          value = "300" },
    ]
    secrets = [
      { name = "DB_USER";     valueFrom = "${var.db_secret_arn}:username::" },
      { name = "DB_PASSWORD"; valueFrom = "${var.db_secret_arn}:password::" },
      { name = "API_KEYS";    valueFrom = var.api_keys_secret_arn },
    ]
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.api.name
        "awslogs-region"        = var.aws_region
        "awslogs-stream-prefix" = "ecs"
      }
    }
    healthCheck = {
      command     = ["CMD-SHELL", "wget -qO- http://localhost:${var.api_port}/health || exit 1"]
      interval    = 30; timeout = 5; retries = 3; startPeriod = 60
    }
    readonlyRootFilesystem = true
    linuxParameters = {
      capabilities = { drop = ["ALL"]; add = [] }
      initProcessEnabled = true
    }
  }])
  tags = var.tags
}

resource "aws_ecs_task_definition" "worker" {
  family                   = "${var.name}-worker"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.worker_cpu
  memory                   = var.worker_memory
  execution_role_arn       = aws_iam_role.execution.arn
  task_role_arn            = aws_iam_role.task.arn

  container_definitions = jsonencode([{
    name      = "worker"
    image     = var.worker_image
    essential = true
    environment = [
      { name = "NODE_ENV";               value = var.environment },
      { name = "DB_HOST";                value = var.db_host },
      { name = "DB_PORT";                value = "5432" },
      { name = "DB_NAME";                value = var.db_name },
      { name = "REDIS_HOST";             value = var.redis_host },
      { name = "REDIS_PORT";             value = "6379" },
      { name = "REDIS_TLS";              value = var.environment == "prod" ? "true" : "false" },
      { name = "DB_SSL";                 value = "true" },
      { name = "WORKER_CONCURRENCY";     value = tostring(var.worker_concurrency) },
      { name = "LOG_LEVEL";              value = var.environment == "prod" ? "info" : "debug" },
      { name = "SERVICE_NAME";           value = "cyberwatch-worker" },
      { name = "ALERT_SCORE_THRESHOLD";  value = tostring(var.alert_score_threshold) },
    ]
    secrets = [
      { name = "DB_USER";     valueFrom = "${var.db_secret_arn}:username::" },
      { name = "DB_PASSWORD"; valueFrom = "${var.db_secret_arn}:password::" },
    ]
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.worker.name
        "awslogs-region"        = var.aws_region
        "awslogs-stream-prefix" = "ecs"
      }
    }
    readonlyRootFilesystem = true
    linuxParameters = {
      capabilities = { drop = ["ALL"]; add = [] }
      initProcessEnabled = true
    }
  }])
  tags = var.tags
}

resource "aws_ecs_service" "api" {
  name                               = "${var.name}-api"
  cluster                            = aws_ecs_cluster.main.id
  task_definition                    = aws_ecs_task_definition.api.arn
  desired_count                      = var.api_desired_count
  launch_type                        = "FARGATE"
  deployment_minimum_healthy_percent = 100
  deployment_maximum_percent         = 200
  deployment_circuit_breaker { enable = true; rollback = true }
  network_configuration {
    subnets          = var.private_subnet_ids
    security_groups  = [aws_security_group.ecs_tasks.id]
    assign_public_ip = false
  }
  load_balancer {
    target_group_arn = var.target_group_arn
    container_name   = "api"
    container_port   = var.api_port
  }
  lifecycle { ignore_changes = [task_definition, desired_count] }
  tags = var.tags
}

resource "aws_ecs_service" "worker" {
  name                               = "${var.name}-worker"
  cluster                            = aws_ecs_cluster.main.id
  task_definition                    = aws_ecs_task_definition.worker.arn
  desired_count                      = var.worker_desired_count
  launch_type                        = "FARGATE"
  deployment_minimum_healthy_percent = 50
  deployment_maximum_percent         = 200
  deployment_circuit_breaker { enable = true; rollback = true }
  network_configuration {
    subnets          = var.private_subnet_ids
    security_groups  = [aws_security_group.ecs_tasks.id]
    assign_public_ip = false
  }
  lifecycle { ignore_changes = [task_definition, desired_count] }
  tags = var.tags
}

resource "aws_appautoscaling_target" "api" {
  max_capacity       = var.api_max_count
  min_capacity       = var.api_min_count
  resource_id        = "service/${aws_ecs_cluster.main.name}/${aws_ecs_service.api.name}"
  scalable_dimension = "ecs:service:DesiredCount"
  service_namespace  = "ecs"
}

resource "aws_appautoscaling_policy" "api_cpu" {
  name               = "${var.name}-api-cpu-scaling"
  policy_type        = "TargetTrackingScaling"
  resource_id        = aws_appautoscaling_target.api.resource_id
  scalable_dimension = aws_appautoscaling_target.api.scalable_dimension
  service_namespace  = aws_appautoscaling_target.api.service_namespace
  target_tracking_scaling_policy_configuration {
    predefined_metric_specification { predefined_metric_type = "ECSServiceAverageCPUUtilization" }
    target_value       = 60.0
    scale_in_cooldown  = 300
    scale_out_cooldown = 60
  }
}
