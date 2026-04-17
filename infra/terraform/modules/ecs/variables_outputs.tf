variable "name" { type = string }
variable "environment" { type = string }
variable "aws_region" { type = string }
variable "vpc_id" { type = string }
variable "private_subnet_ids" { type = list(string) }
variable "alb_security_group_id" { type = string }
variable "target_group_arn" { type = string }
variable "alb_arn_suffix" { type = string }
variable "target_group_arn_suffix" { type = string }
variable "api_image" { type = string }
variable "worker_image" { type = string }
variable "db_host" { type = string }
variable "db_name" { type = string }
variable "db_secret_arn" { type = string }
variable "api_keys_secret_arn" { type = string }
variable "redis_host" { type = string }
variable "secrets_arns" { type = list(string) }
variable "alert_score_threshold" { type = number; default = 7.0 }
variable "api_port" { type = number; default = 3000 }
variable "api_cpu" { type = number; default = 256 }
variable "api_memory" { type = number; default = 512 }
variable "api_desired_count" { type = number; default = 2 }
variable "api_min_count" { type = number; default = 1 }
variable "api_max_count" { type = number; default = 10 }
variable "worker_cpu" { type = number; default = 256 }
variable "worker_memory" { type = number; default = 512 }
variable "worker_desired_count" { type = number; default = 1 }
variable "worker_concurrency" { type = number; default = 5 }
variable "log_retention_days" { type = number; default = 30 }
variable "tags" { type = map(string); default = {} }

output "cluster_name"           { value = aws_ecs_cluster.main.name }
output "cluster_arn"            { value = aws_ecs_cluster.main.arn }
output "api_service_name"       { value = aws_ecs_service.api.name }
output "worker_service_name"    { value = aws_ecs_service.worker.name }
output "task_security_group_id" { value = aws_security_group.ecs_tasks.id }
output "task_role_arn"          { value = aws_iam_role.task.arn }
output "execution_role_arn"     { value = aws_iam_role.execution.arn }
