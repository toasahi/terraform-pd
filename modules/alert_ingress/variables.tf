variable "name" {
  description = "Name of the REST API and prefix of related resources."
  type        = string
}

variable "domain_name" {
  description = "Custom domain of the ingest endpoint (e.g. alerts.mgmt.example.com). Alert sources only ever see this name."
  type        = string
}

variable "hosted_zone_id" {
  description = "Public Route 53 hosted zone that holds domain_name (external senders cannot resolve private zones)."
  type        = string
}

variable "stage_name" {
  description = "Name of the API stage."
  type        = string
  default     = "live"
}

variable "allowed_source_cidrs" {
  description = "Public IPv4 CIDRs allowed to call the endpoint (NAT egress IPs of the prod / management EKS VPCs)."
  type        = list(string)

  validation {
    condition     = length(var.allowed_source_cidrs) > 0 && alltrue([for cidr in var.allowed_source_cidrs : can(cidrhost(cidr, 0))])
    error_message = "allowed_source_cidrs must be a non-empty list of IPv4 CIDRs."
  }
}

variable "authorizer_function" {
  description = "REQUEST authorizer Lambda function."
  type = object({
    function_name = string
    invoke_arn    = string
  })
}

variable "authorizer_result_ttl_seconds" {
  description = "Authorizer decision cache TTL, in seconds (the policy is scoped to the exact method ARN)."
  type        = number
  default     = 300
}

variable "ingest_function" {
  description = "Lambda function that receives the Alertmanager webhooks."
  type = object({
    function_name = string
    invoke_arn    = string
  })
}

variable "throttling_rate_limit_rps" {
  description = "Stage steady-state request rate limit, in requests per second. Keep well above peak load: Alertmanager does not retry 429."
  type        = number
  default     = 50
}

variable "throttling_burst_limit" {
  description = "Stage burst limit, in requests."
  type        = number
  default     = 200
}

variable "waf_rate_limit_per_5_minutes" {
  description = "Per-IP request count over 5 minutes above which the WAF rate-based rule matches."
  type        = number
  default     = 2000
}

variable "enable_waf_rate_limit_block" {
  description = "Whether the rate-based rule blocks (true) or only counts (false). A block is a 403, which Alertmanager does not retry."
  type        = bool
  default     = false
}

variable "enable_waf_managed_rules_block" {
  description = "Whether AWS managed rule groups block (true) or only count (false). The IP allow-list is always enforced."
  type        = bool
  default     = false
}

variable "log_retention_days" {
  description = "Retention of the access log and WAF log groups, in days."
  type        = number
  default     = 90
}
