# Alarms on the alert pipeline itself ("who watches the watcher"). The topic is encrypted with a
# customer managed key because CloudWatch alarms cannot publish to topics that use aws/sns.

data "aws_region" "current" {}

data "aws_caller_identity" "current" {}

data "aws_iam_policy_document" "topic_key" {
  statement {
    sid       = "AccountAdministration"
    actions   = ["kms:*"]
    resources = ["*"]

    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"]
    }
  }

  statement {
    sid       = "CloudWatchAlarms"
    actions   = ["kms:Decrypt", "kms:GenerateDataKey*"]
    resources = ["*"]

    principals {
      type        = "Service"
      identifiers = ["cloudwatch.amazonaws.com"]
    }
  }
}

resource "aws_kms_key" "topic" {
  description         = "${var.name} alarm topic"
  enable_key_rotation = true
  policy              = data.aws_iam_policy_document.topic_key.json
}

resource "aws_sns_topic" "alarm" {
  name              = "${var.name}-alarms"
  kms_master_key_id = aws_kms_key.topic.id
}

resource "aws_sns_topic_subscription" "email" {
  for_each = toset(var.alarm_email_endpoints)

  topic_arn = aws_sns_topic.alarm.arn
  protocol  = "email"
  endpoint  = each.value
}

locals {
  alarm_actions = [aws_sns_topic.alarm.arn]
}

resource "aws_cloudwatch_metric_alarm" "queue_age" {
  for_each = var.queues

  alarm_name          = "${var.name}-${each.key}-oldest-message-age"
  alarm_description   = "Messages in ${each.value.queue_name} are not being consumed."
  namespace           = "AWS/SQS"
  metric_name         = "ApproximateAgeOfOldestMessage"
  dimensions          = { QueueName = each.value.queue_name }
  statistic           = "Maximum"
  period              = var.period_seconds
  evaluation_periods  = 5
  comparison_operator = "GreaterThanThreshold"
  threshold           = each.value.max_oldest_message_seconds
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.alarm_actions
  ok_actions          = local.alarm_actions
}

resource "aws_cloudwatch_metric_alarm" "dead_letter" {
  for_each = var.dead_letter_queue_names

  alarm_name          = "${var.name}-${each.key}-dlq-not-empty"
  alarm_description   = "Messages reached ${each.value}. Investigate, then redrive (StartMessageMoveTask)."
  namespace           = "AWS/SQS"
  metric_name         = "ApproximateNumberOfMessagesVisible"
  dimensions          = { QueueName = each.value }
  statistic           = "Maximum"
  period              = var.period_seconds
  evaluation_periods  = 1
  comparison_operator = "GreaterThanThreshold"
  threshold           = 0
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.alarm_actions
  ok_actions          = local.alarm_actions
}

resource "aws_cloudwatch_metric_alarm" "lambda_errors" {
  for_each = var.lambda_function_names

  alarm_name          = "${var.name}-${each.key}-errors"
  alarm_description   = "Lambda ${each.value} reported errors."
  namespace           = "AWS/Lambda"
  metric_name         = "Errors"
  dimensions          = { FunctionName = each.value }
  statistic           = "Sum"
  period              = var.period_seconds
  evaluation_periods  = 1
  comparison_operator = "GreaterThanThreshold"
  threshold           = 0
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.alarm_actions
  ok_actions          = local.alarm_actions
}

resource "aws_cloudwatch_metric_alarm" "lambda_throttles" {
  for_each = var.throttle_watched_functions

  alarm_name          = "${var.name}-${each.key}-throttles"
  alarm_description   = "Lambda ${var.lambda_function_names[each.key]} is throttled (reserved concurrency below the event source maximum concurrency?)."
  namespace           = "AWS/Lambda"
  metric_name         = "Throttles"
  dimensions          = { FunctionName = var.lambda_function_names[each.key] }
  statistic           = "Sum"
  period              = var.period_seconds
  evaluation_periods  = 5
  comparison_operator = "GreaterThanThreshold"
  threshold           = 0
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.alarm_actions
  ok_actions          = local.alarm_actions
}

resource "aws_cloudwatch_metric_alarm" "api_errors" {
  for_each = { "4XXError" = "client", "5XXError" = "server" }

  alarm_name          = "${var.name}-api-${each.value}-errors"
  alarm_description   = "Ingest API returned ${each.key}. Alertmanager retries 5xx only; every 4xx is a dropped notification."
  namespace           = "AWS/ApiGateway"
  metric_name         = each.key
  dimensions          = { ApiName = var.api.api_name, Stage = var.api.stage_name }
  statistic           = "Sum"
  period              = var.period_seconds
  evaluation_periods  = 1
  comparison_operator = "GreaterThanThreshold"
  threshold           = 0
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.alarm_actions
  ok_actions          = local.alarm_actions
}

resource "aws_cloudwatch_metric_alarm" "waf_blocked" {
  alarm_name        = "${var.name}-waf-blocked-requests"
  alarm_description = "WAF blocked requests to the ingest API (403, not retried by Alertmanager). Check the allow-list against the senders' NAT IPs."
  namespace         = "AWS/WAFV2"
  metric_name       = "BlockedRequests"
  dimensions = {
    WebACL = var.web_acl_name
    Region = data.aws_region.current.region
    Rule   = "ALL"
  }
  statistic           = "Sum"
  period              = var.period_seconds
  evaluation_periods  = 1
  comparison_operator = "GreaterThanThreshold"
  threshold           = 0
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.alarm_actions
  ok_actions          = local.alarm_actions
}

resource "aws_cloudwatch_metric_alarm" "ecs_running_tasks" {
  for_each = var.ecs_services

  alarm_name          = "${var.name}-${each.key}-running-tasks"
  alarm_description   = "ECS service ${each.value.service_name} runs fewer than ${each.value.min_running_tasks} tasks."
  namespace           = "ECS/ContainerInsights"
  metric_name         = "RunningTaskCount"
  dimensions          = { ClusterName = each.value.cluster_name, ServiceName = each.value.service_name }
  statistic           = "Minimum"
  period              = var.period_seconds
  evaluation_periods  = 3
  comparison_operator = "LessThanThreshold"
  threshold           = each.value.min_running_tasks
  treat_missing_data  = "breaching"
  alarm_actions       = local.alarm_actions
  ok_actions          = local.alarm_actions
}
