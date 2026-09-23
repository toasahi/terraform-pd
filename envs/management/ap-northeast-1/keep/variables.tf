variable "account_id" {
  description = "Management account ID (guards against applying to the wrong account)."
  type        = string
}

variable "region" {
  description = "AWS region."
  type        = string
}

variable "state_bucket_name" {
  description = "Terraform state bucket (for reading the foundation outputs)."
  type        = string
}

variable "public_zone_name" {
  description = "Public hosted zone of the management account (e.g. mgmt.example.com)."
  type        = string
}

variable "operator_cidrs" {
  description = "VPN / office CIDRs allowed to open the Keep UI."
  type        = list(string)
}

variable "keep_api_image_digest" {
  description = "Digest (sha256:...) of the mirrored Keep backend image in ECR."
  type        = string
}

variable "keep_ui_image_digest" {
  description = "Digest (sha256:...) of the mirrored Keep frontend image in ECR."
  type        = string
}

variable "api_desired_count" {
  description = "Number of Keep API tasks."
  type        = number
  default     = 2
}

variable "enable_dedicated_scheduler" {
  description = "Split the workflow scheduler into its own single-task service (see phase-1 exit criterion 6)."
  type        = bool
  default     = false
}

variable "keep_limit_concurrency" {
  description = "Keep KEEP_LIMIT_CONCURRENCY for /alerts/event."
  type        = string
  default     = "100/minute"
}
