# Alert pipeline (phase 1, Tokyo):
#   Alertmanager (prod EKS / management EKS)
#     -> alert_ingress (REST API + WAF + REQUEST authorizer) -> ingest Lambda
#     -> Journal (DynamoDB, conditional put) + alerts.fifo
#     -> router Lambda: critical -> in-house notifier queue + SNS critical-direct (both Keep-independent),
#                       all -> keep-delivery.fifo
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
  queues = merge(
    {
      # visibility timeout = 6 x consumer Lambda timeout
      alerts        = { visibility_timeout_seconds = 6 * local.function_timeouts_seconds.router }
      keep_delivery = { visibility_timeout_seconds = 6 * local.function_timeouts_seconds.dispatcher }
    },
    # Queue consumed by the in-house notifier's Lambda (event source mapping on the tool side).
    local.create_inhouse_queue ? {
      critical_inhouse = { visibility_timeout_seconds = var.inhouse_notifier_visibility_timeout_seconds }
    } : {},
  )
}

# --- Keep-independent channels for critical alerts ------------------------------------------
# Both channels always receive every critical transition (at-least-once; consumers deduplicate on
# transitionId). The router records each successful channel in the Journal so that a retry only
# re-sends the channel that failed.

# 1) In-house notifier (primary): a Lambda in this account triggered by an SQS queue. By default the
#    queue is created here (FIFO, grouped per alert); an existing queue of the tool can be used instead.
locals {
  create_inhouse_queue = var.inhouse_notifier_existing_queue_arn == null

  # arn:aws:sqs:<region>:<account>:<name>
  existing_inhouse_queue = local.create_inhouse_queue ? null : {
    region  = split(":", var.inhouse_notifier_existing_queue_arn)[3]
    account = split(":", var.inhouse_notifier_existing_queue_arn)[4]
    name    = split(":", var.inhouse_notifier_existing_queue_arn)[5]
  }

  inhouse_queue_arn  = local.create_inhouse_queue ? module.queues.queue_arns["critical_inhouse"] : var.inhouse_notifier_existing_queue_arn
  inhouse_queue_name = local.create_inhouse_queue ? module.queues.queue_names["critical_inhouse"] : local.existing_inhouse_queue.name
  inhouse_queue_url = (
    local.create_inhouse_queue
    ? module.queues.queue_urls["critical_inhouse"]
    : "https://sqs.${local.existing_inhouse_queue.region}.amazonaws.com/${local.existing_inhouse_queue.account}/${local.existing_inhouse_queue.name}"
  )
}

# 2) SNS critical-direct (parallel channel): e-mail today; Slack etc. can subscribe later.
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

# Per-source ingest tokens: JSON object {"<source>": "<sha256 hex of token>" | ["<digest>", ...]}.
# The value is written by an operator, never by Terraform (see docs/alertmanager-receiver.md).
resource "aws_secretsmanager_secret" "source_tokens" {
  name        = "${local.name}/source-token-digests"
  description = "sha256 digests of the bearer tokens each alert source (Alertmanager) presents"
}
