resource "aws_sns_topic" "alerts" {
  name = "${var.name}-alerts"
  tags = var.tags
}

resource "aws_sns_topic_subscription" "email" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

# ── ECS alarms ────────────────────────────────────────────────────────────────

resource "aws_cloudwatch_metric_alarm" "api_high_cpu" {
  alarm_name          = "${var.name}-api-high-cpu"
  alarm_description   = "API CPU above 80% — enrichment queue may be backing up"
  namespace           = "AWS/ECS"
  metric_name         = "CPUUtilization"
  dimensions          = { ClusterName = var.cluster_name; ServiceName = var.api_service_name }
  statistic           = "Average"
  period              = 60; evaluation_periods = 5; threshold = 80
  comparison_operator = "GreaterThanThreshold"; treat_missing_data = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]; ok_actions = [aws_sns_topic.alerts.arn]
  tags                = var.tags
}

resource "aws_cloudwatch_metric_alarm" "worker_no_tasks" {
  alarm_name          = "${var.name}-worker-no-running-tasks"
  alarm_description   = "CRITICAL: Worker has 0 running tasks — IOC enrichment halted"
  namespace           = "ECS/ContainerInsights"
  metric_name         = "RunningTaskCount"
  dimensions          = { ClusterName = var.cluster_name; ServiceName = var.worker_service_name }
  statistic           = "Minimum"
  period              = 60; evaluation_periods = 2; threshold = 1
  comparison_operator = "LessThanThreshold"; treat_missing_data = "breaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  tags                = var.tags
}

# ── ALB alarms ────────────────────────────────────────────────────────────────

resource "aws_cloudwatch_metric_alarm" "alb_5xx" {
  alarm_name          = "${var.name}-alb-5xx"
  alarm_description   = "ALB 5xx errors — API may be crashing"
  namespace           = "AWS/ApplicationELB"
  metric_name         = "HTTPCode_Target_5XX_Count"
  dimensions          = { LoadBalancer = var.alb_arn_suffix }
  statistic           = "Sum"
  period              = 60; evaluation_periods = 3; threshold = 10
  comparison_operator = "GreaterThanThreshold"; treat_missing_data = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  tags                = var.tags
}

resource "aws_cloudwatch_metric_alarm" "alb_latency_p99" {
  alarm_name          = "${var.name}-alb-p99-latency"
  alarm_description   = "API p99 latency above 3s — check DB query performance"
  namespace           = "AWS/ApplicationELB"
  metric_name         = "TargetResponseTime"
  dimensions          = { LoadBalancer = var.alb_arn_suffix }
  extended_statistic  = "p99"
  period              = 60; evaluation_periods = 5; threshold = 3
  comparison_operator = "GreaterThanThreshold"; treat_missing_data = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  tags                = var.tags
}

# ── RDS alarms ────────────────────────────────────────────────────────────────

resource "aws_cloudwatch_metric_alarm" "rds_high_cpu" {
  alarm_name          = "${var.name}-rds-high-cpu"
  alarm_description   = "RDS CPU above 80%"
  namespace           = "AWS/RDS"
  metric_name         = "CPUUtilization"
  dimensions          = { DBInstanceIdentifier = var.rds_identifier }
  statistic           = "Average"
  period              = 60; evaluation_periods = 5; threshold = 80
  comparison_operator = "GreaterThanThreshold"; treat_missing_data = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  tags                = var.tags
}

resource "aws_cloudwatch_metric_alarm" "rds_low_storage" {
  alarm_name          = "${var.name}-rds-low-storage"
  alarm_description   = "RDS free storage below 5GB"
  namespace           = "AWS/RDS"
  metric_name         = "FreeStorageSpace"
  dimensions          = { DBInstanceIdentifier = var.rds_identifier }
  statistic           = "Average"
  period              = 300; evaluation_periods = 3; threshold = 5368709120
  comparison_operator = "LessThanThreshold"; treat_missing_data = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  tags                = var.tags
}

# ── Log metric filters ────────────────────────────────────────────────────────

resource "aws_cloudwatch_log_metric_filter" "api_errors" {
  name           = "${var.name}-api-errors"
  pattern        = "{ $.level = \"error\" }"
  log_group_name = "/ecs/${var.name}/api"
  metric_transformation {
    name          = "ApiErrorCount"
    namespace     = "CyberWatch/${var.environment}"
    value         = "1"
    default_value = "0"
  }
}

resource "aws_cloudwatch_log_metric_filter" "alerts_fired" {
  name           = "${var.name}-alerts-fired"
  pattern        = "{ $.message = \"Alert fired\" }"
  log_group_name = "/ecs/${var.name}/worker"
  metric_transformation {
    name          = "AlertsFiredCount"
    namespace     = "CyberWatch/${var.environment}"
    value         = "1"
    default_value = "0"
  }
}

resource "aws_cloudwatch_metric_alarm" "api_error_rate" {
  alarm_name          = "${var.name}-api-error-rate"
  alarm_description   = "More than 10 application errors per minute"
  namespace           = "CyberWatch/${var.environment}"
  metric_name         = "ApiErrorCount"
  statistic           = "Sum"
  period              = 60; evaluation_periods = 3; threshold = 10
  comparison_operator = "GreaterThanThreshold"; treat_missing_data = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  tags                = var.tags
}

# ── CloudWatch Dashboard ──────────────────────────────────────────────────────

resource "aws_cloudwatch_dashboard" "main" {
  dashboard_name = "${var.name}-overview"
  dashboard_body = jsonencode({
    widgets = [
      {
        type = "metric"; x = 0; y = 0; width = 12; height = 6
        properties = {
          title   = "API CPU & Memory"
          period  = 60
          metrics = [
            ["AWS/ECS","CPUUtilization","ClusterName",var.cluster_name,"ServiceName",var.api_service_name],
            ["AWS/ECS","MemoryUtilization","ClusterName",var.cluster_name,"ServiceName",var.api_service_name],
          ]
        }
      },
      {
        type = "metric"; x = 12; y = 0; width = 12; height = 6
        properties = {
          title   = "ALB Requests & 5xx Errors"
          period  = 60
          metrics = [
            ["AWS/ApplicationELB","RequestCount","LoadBalancer",var.alb_arn_suffix,{stat="Sum"}],
            ["AWS/ApplicationELB","HTTPCode_Target_5XX_Count","LoadBalancer",var.alb_arn_suffix,{stat="Sum",color="#d62728"}],
          ]
        }
      },
      {
        type = "metric"; x = 0; y = 6; width = 12; height = 6
        properties = {
          title   = "Alerts Fired (custom metric)"
          period  = 300
          metrics = [["CyberWatch/${var.environment}","AlertsFiredCount",{stat="Sum",color="#ff7f0e"}]]
        }
      },
      {
        type = "metric"; x = 12; y = 6; width = 12; height = 6
        properties = {
          title   = "RDS CPU & Connections"
          period  = 60
          metrics = [
            ["AWS/RDS","CPUUtilization","DBInstanceIdentifier",var.rds_identifier],
            ["AWS/RDS","DatabaseConnections","DBInstanceIdentifier",var.rds_identifier,{yAxis="right"}],
          ]
        }
      },
    ]
  })
}

variable "name" { type = string }
variable "environment" { type = string }
variable "cluster_name" { type = string }
variable "api_service_name" { type = string }
variable "worker_service_name" { type = string }
variable "alb_arn_suffix" { type = string }
variable "rds_identifier" { type = string }
variable "alert_email" { type = string }
variable "tags" { type = map(string); default = {} }

output "sns_topic_arn"  { value = aws_sns_topic.alerts.arn }
output "dashboard_name" { value = aws_cloudwatch_dashboard.main.dashboard_name }
