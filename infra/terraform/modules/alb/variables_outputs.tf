variable "name" { type = string }
variable "vpc_id" { type = string }
variable "public_subnet_ids" { type = list(string) }
variable "certificate_arn" { type = string }
variable "api_port" { type = number; default = 3000 }
variable "enable_deletion_protection" { type = bool; default = false }
variable "tags" { type = map(string); default = {} }

output "alb_arn"             { value = aws_lb.main.arn }
output "alb_dns_name"        { value = aws_lb.main.dns_name }
output "alb_zone_id"         { value = aws_lb.main.zone_id }
output "alb_sg_id"           { value = aws_security_group.alb.id }
output "target_group_arn"    { value = aws_lb_target_group.api.arn }
output "alb_arn_suffix"      { value = aws_lb.main.arn_suffix }
output "target_group_arn_suffix" { value = aws_lb_target_group.api.arn_suffix }
