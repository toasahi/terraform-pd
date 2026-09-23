# Alert pipeline (phase 1, Tokyo):
#   Alertmanager (prod EKS / management EKS)
#     -> alert_ingress (REST API + WAF + REQUEST authorizer) -> ingest Lambda
#     -> Journal (DynamoDB, conditional put) + alerts.fifo
#     -> router Lambda: critical -> SNS critical-direct (Keep-independent), all -> keep-delivery.fifo
#     -> dispatcher Lambda (VPC, capped concurrency) -> Keep API (internal ALB)
# All Lambda functions are TypeScript + Effect on the Node.js 24 managed runtime (lambda/).

data "terraform_remote_state" "foundation" {
  backend = "s3"

  config = {
    bucket = var.state_bucket_name
    key    = "management/ap-northeast-1/foundation.tfstate"
    region = var.region
  }
}

data "terraform_remote_state" "keep" {
  backend = "s3"

  config = {
    bucket = var.state_bucket_name
    key    = "management/ap-northeast-1/keep.tfstate"
    region = var.region
  }
}

locals {
  foundation = data.terraform_remote_state.foundation.outputs
  keep       = data.terraform_remote_state.keep.outputs

  name = "alert-pipeline"
}

module "journal" {
  source = "../../../../modules/alert_journal"

  table_name = "AlertEventJournal"
}

module "queues" {
  source = "../../../../modules/alert_queues"

  name_prefix = local.name
  queues = {
    # visibility timeout = 6 x consumer Lambda timeout
    alerts        = { visibility_timeout_seconds = 6 * local.function_timeouts_seconds.router }
    keep_delivery = { visibility_timeout_seconds = 6 * local.function_timeouts_seconds.dispatcher }
  }
}

# Direct, Keep-independent channel for critical alerts. During the parallel run with PagerDuty an
# HTTPS subscription can point at a PagerDuty (Amazon SNS) integration URL.
resource "aws_sns_topic" "critical" {
  name              = "${local.name}-critical-direct"
  kms_master_key_id = "alias/aws/sns"
}

resource "aws_sns_topic_subscription" "critical_email" {
  for_each = toset(var.critical_email_endpoints)

  topic_arn = aws_sns_topic.critical.arn
  protocol  = "email"
  endpoint  = each.value
}

resource "aws_sns_topic_subscription" "critical_https" {
  count = nonsensitive(length(var.critical_https_endpoints))

  topic_arn              = aws_sns_topic.critical.arn
  protocol               = "https"
  endpoint               = var.critical_https_endpoints[count.index]
  endpoint_auto_confirms = true
}

# Per-source ingest tokens: JSON object {"<source>": "<sha256 hex of token>" | ["<digest>", ...]}.
# The value is written by an operator, never by Terraform (see docs/alertmanager-receiver.md).
resource "aws_secretsmanager_secret" "source_tokens" {
  name        = "${local.name}/source-token-digests"
  description = "sha256 digests of the bearer tokens each alert source (Alertmanager) presents"
}
