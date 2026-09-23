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
  description = "Alert severities (labels.severity) delivered directly via SNS, independent of Keep."
  type        = list(string)
  default     = ["critical"]
}

variable "critical_email_endpoints" {
  description = "E-mail subscribers of the critical-direct topic."
  type        = list(string)
  default     = []
}

variable "critical_https_endpoints" {
  description = "HTTPS subscribers of the critical-direct topic (e.g. a PagerDuty Amazon SNS integration URL during the parallel run)."
  type        = list(string)
  default     = []
  sensitive   = true
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
