# Deployment package: one esbuild bundle (lambda/dist/lambda.zip, built by helpers/build-lambda.sh)
# shared by all four functions; each function selects its export through `handler`.
locals {
  lambda_package_path = coalesce(var.lambda_package_path, "${path.module}/../../../../lambda/dist/lambda.zip")

  function_timeouts_seconds = {
    authorizer = 10
    ingest     = 29 # API Gateway integration timeout
    router     = 30
    dispatcher = 60
  }
}

# --- authorizer ------------------------------------------------------------------------------

data "aws_iam_policy_document" "authorizer" {
  statement {
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [aws_secretsmanager_secret.source_tokens.arn]
  }
}

module "authorizer" {
  source = "../../../../modules/nodejs_lambda_function"

  function_name   = "${local.name}-authorizer"
  description     = "REQUEST authorizer: per-source bearer token"
  handler         = "index.authorizer"
  package_path    = local.lambda_package_path
  timeout_seconds = local.function_timeouts_seconds.authorizer
  memory_size_mb  = 256
  policy_json     = data.aws_iam_policy_document.authorizer.json

  environment_variables = {
    SOURCE_TOKENS_SECRET_ID = aws_secretsmanager_secret.source_tokens.arn
  }
}

# --- ingest ----------------------------------------------------------------------------------

data "aws_iam_policy_document" "ingest" {
  statement {
    actions   = ["dynamodb:PutItem", "dynamodb:GetItem", "dynamodb:UpdateItem"]
    resources = [module.journal.table_arn]
  }

  statement {
    actions   = ["sqs:SendMessage"]
    resources = [module.queues.queue_arns["alerts"]]
  }
}

module "ingest" {
  source = "../../../../modules/nodejs_lambda_function"

  function_name   = "${local.name}-ingest"
  description     = "Journals Alertmanager webhooks and enqueues them on alerts.fifo"
  handler         = "index.ingest"
  package_path    = local.lambda_package_path
  timeout_seconds = local.function_timeouts_seconds.ingest
  policy_json     = data.aws_iam_policy_document.ingest.json

  environment_variables = {
    JOURNAL_TABLE_NAME = module.journal.table_name
    JOURNAL_TTL_DAYS   = tostring(var.journal_ttl_days)
    ALERTS_QUEUE_URL   = module.queues.queue_urls["alerts"]
  }
}

# --- router ----------------------------------------------------------------------------------

data "aws_iam_policy_document" "router" {
  statement {
    actions   = ["sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:GetQueueAttributes"]
    resources = [module.queues.queue_arns["alerts"]]
  }

  statement {
    actions   = ["sqs:SendMessage"]
    resources = [module.queues.queue_arns["keep_delivery"]]
  }

  statement {
    actions   = ["sqs:SendMessage"]
    resources = [local.inhouse_queue_arn]
  }

  dynamic "statement" {
    for_each = var.inhouse_notifier_kms_key_arn == null ? [] : [var.inhouse_notifier_kms_key_arn]

    content {
      actions   = ["kms:GenerateDataKey", "kms:Decrypt"]
      resources = [statement.value]
    }
  }

  statement {
    actions   = ["sns:Publish"]
    resources = [aws_sns_topic.critical.arn]
  }

  # GetItem: channels already delivered (retries only re-send the failed channel).
  statement {
    actions   = ["dynamodb:GetItem", "dynamodb:UpdateItem"]
    resources = [module.journal.table_arn]
  }
}

module "router" {
  source = "../../../../modules/nodejs_lambda_function"

  function_name   = "${local.name}-router"
  description     = "Delivers critical alerts to the in-house notifier and SNS, forwards all alerts to keep-delivery.fifo"
  handler         = "index.router"
  package_path    = local.lambda_package_path
  timeout_seconds = local.function_timeouts_seconds.router
  policy_json     = data.aws_iam_policy_document.router.json

  environment_variables = {
    JOURNAL_TABLE_NAME         = module.journal.table_name
    CRITICAL_TOPIC_ARN         = aws_sns_topic.critical.arn
    INHOUSE_NOTIFIER_QUEUE_URL = local.inhouse_queue_url
    CRITICAL_SEVERITIES        = join(",", var.critical_severities)
    KEEP_DELIVERY_QUEUE_URL    = module.queues.queue_urls["keep_delivery"]
  }
}

resource "aws_lambda_event_source_mapping" "router" {
  event_source_arn        = module.queues.queue_arns["alerts"]
  function_name           = module.router.function_arn
  batch_size              = 10
  function_response_types = ["ReportBatchItemFailures"]

  scaling_config {
    maximum_concurrency = 10
  }
}

# --- dispatcher ------------------------------------------------------------------------------

resource "aws_security_group" "dispatcher" {
  name        = "${local.name}-dispatcher"
  description = "Dispatcher Lambda (Keep API via internal ALB, AWS APIs)"
  vpc_id      = local.foundation.vpc_id
}

resource "aws_vpc_security_group_egress_rule" "dispatcher_https" {
  security_group_id = aws_security_group.dispatcher.id
  description       = "HTTPS to the Keep ALB and AWS APIs"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = "0.0.0.0/0"
}

data "aws_iam_policy_document" "dispatcher" {
  statement {
    actions   = ["sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:GetQueueAttributes"]
    resources = [module.queues.queue_arns["keep_delivery"]]
  }

  statement {
    actions   = ["dynamodb:UpdateItem"]
    resources = [module.journal.table_arn]
  }

  statement {
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [local.keep.api_key_secret_arn]
  }
}

module "dispatcher" {
  source = "../../../../modules/nodejs_lambda_function"

  function_name   = "${local.name}-dispatcher"
  description     = "Pushes alerts from keep-delivery.fifo to Keep (POST /alerts/event/prometheus)"
  handler         = "index.dispatcher"
  package_path    = local.lambda_package_path
  timeout_seconds = local.function_timeouts_seconds.dispatcher
  policy_json     = data.aws_iam_policy_document.dispatcher.json

  # Must be >= the event source maximum concurrency, otherwise Lambda throttles the poller.
  reserved_concurrent_executions = var.dispatcher_reserved_concurrency

  vpc_config = {
    subnet_ids         = local.foundation.private_subnet_ids
    security_group_ids = [aws_security_group.dispatcher.id]
  }

  environment_variables = {
    JOURNAL_TABLE_NAME     = module.journal.table_name
    KEEP_API_URL           = local.keep.api_url
    KEEP_API_KEY_SECRET_ID = local.keep.api_key_secret_arn
    KEEP_PROVIDER_TYPE     = "prometheus"
  }
}

# The concurrency cap towards Keep (architecture review 3.3 / keephq/keep#5496). maximum_concurrency
# is the control AWS recommends for SQS sources; it also bounds the backlog drain after a Keep outage.
resource "aws_lambda_event_source_mapping" "dispatcher" {
  event_source_arn        = module.queues.queue_arns["keep_delivery"]
  function_name           = module.dispatcher.function_arn
  batch_size              = 5
  function_response_types = ["ReportBatchItemFailures"]

  scaling_config {
    maximum_concurrency = var.dispatcher_maximum_concurrency
  }
}
