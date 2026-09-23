variable "account_id" {
  description = "Management account ID (guards against applying to the wrong account)."
  type        = string
}

variable "region" {
  description = "AWS region."
  type        = string
}

variable "state_bucket_name" {
  description = "Terraform state bucket (for reading the foundation and keep outputs)."
  type        = string
}

variable "public_zone_name" {
  description = "Public hosted zone of the management account; the endpoint is alerts.<zone>."
  type        = string
}

variable "alert_sources" {
  description = <<-EOT
    Alert sources keyed by the name used in the URL path (/v1/alerts/<name>) and in the token secret.
    egress_cidrs are the public NAT egress IPs of the source's EKS VPC (WAF / resource policy allow-list).
  EOT
  type = map(object({
    egress_cidrs = list(string)
  }))

  validation {
    condition     = alltrue([for name in keys(var.alert_sources) : can(regex("^[a-z0-9-]+$", name))])
    error_message = "Source names must be lowercase alphanumerics or hyphens (they are URL path segments)."
  }
}

variable "critical_severities" {
  description = "Alert severities (labels.severity) delivered to the in-house notifier and SNS, independent of Keep."
  type        = list(string)
  default     = ["critical"]
}

variable "critical_email_endpoints" {
  description = "E-mail subscribers of the critical-direct SNS topic (the channel parallel to the in-house notifier)."
  type        = list(string)
  default     = []
}

variable "inhouse_notifier_existing_queue_arn" {
  description = "SQS queue already watched by the in-house notifier Lambda. null creates <name>-critical-inhouse.fifo here for the tool to consume."
  type        = string
  default     = null

  validation {
    condition     = var.inhouse_notifier_existing_queue_arn == null || can(regex("^arn:aws:sqs:[a-z0-9-]+:[0-9]{12}:[A-Za-z0-9_-]+(\\.fifo)?$", var.inhouse_notifier_existing_queue_arn))
    error_message = "inhouse_notifier_existing_queue_arn must be an SQS queue ARN."
  }
}

variable "inhouse_notifier_kms_key_arn" {
  description = "Customer managed KMS key of the existing in-house notifier queue (SSE-KMS), so the router can send to it. null when the queue uses SSE-SQS."
  type        = string
  default     = null
}

variable "inhouse_notifier_visibility_timeout_seconds" {
  description = "Visibility timeout of the queue created for the in-house notifier; at least 6x the tool Lambda's timeout."
  type        = number
  default     = 900
}

variable "inhouse_notifier_max_oldest_message_seconds" {
  description = "Age of the oldest unconsumed critical notification that raises an alarm (the in-house notifier is not consuming)."
  type        = number
  default     = 120
}

variable "alarm_email_endpoints" {
  description = "E-mail subscribers of the pipeline's own alarms."
  type        = list(string)
  default     = []
}

variable "journal_ttl_days" {
  description = "Days a journal entry is kept before DynamoDB TTL removes it (replay window)."
  type        = number
  default     = 30
}

variable "dispatcher_maximum_concurrency" {
  description = "Maximum concurrent Dispatcher invocations (SQS event source maximum concurrency, 2-5 per architecture review 3.3)."
  type        = number
  default     = 3

  validation {
    condition     = var.dispatcher_maximum_concurrency >= 2 && var.dispatcher_maximum_concurrency <= 5
    error_message = "dispatcher_maximum_concurrency must be between 2 and 5."
  }
}

variable "dispatcher_reserved_concurrency" {
  description = "Reserved concurrency of the Dispatcher; must be >= dispatcher_maximum_concurrency."
  type        = number
  default     = 3

  validation {
    condition     = var.dispatcher_reserved_concurrency >= var.dispatcher_maximum_concurrency
    error_message = "dispatcher_reserved_concurrency must be >= dispatcher_maximum_concurrency, otherwise the poller is throttled."
  }
}

variable "lambda_package_path" {
  description = "Path of the Lambda deployment package. null uses lambda/dist/lambda.zip of this repository."
  type        = string
  default     = null
}
