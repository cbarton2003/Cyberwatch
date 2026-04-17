variable "name" { type = string }
variable "vpc_id" { type = string }
variable "private_subnet_ids" { type = list(string) }
variable "allowed_security_group_ids" { type = list(string); default = [] }
variable "db_name" { type = string; default = "cyberwatch" }
variable "db_username" { type = string; default = "cyberwatch" }
variable "instance_class" { type = string; default = "db.t3.micro" }
variable "allocated_storage" { type = number; default = 20 }
variable "max_allocated_storage" { type = number; default = 100 }
variable "multi_az" { type = bool; default = false }
variable "deletion_protection" { type = bool; default = false }
variable "backup_retention_days" { type = number; default = 7 }
variable "kms_key_arn" { type = string; default = null }
variable "tags" { type = map(string); default = {} }

output "endpoint"              { value = aws_db_instance.main.endpoint }
output "address"               { value = aws_db_instance.main.address }
output "port"                  { value = aws_db_instance.main.port }
output "db_name"               { value = aws_db_instance.main.db_name }
output "security_group_id"     { value = aws_security_group.rds.id }
output "master_user_secret_arn" { value = aws_db_instance.main.master_user_secret[0].secret_arn }
