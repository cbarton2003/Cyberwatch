variable "name" { type = string }
variable "vpc_cidr" { type = string; default = "10.0.0.0/16" }
variable "az_count" { type = number; default = 2 }
variable "flow_log_retention_days" { type = number; default = 30 }
variable "tags" { type = map(string); default = {} }
