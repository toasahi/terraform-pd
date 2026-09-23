variable "account_id" {
  description = "Management account ID (guards against applying to the wrong account)."
  type        = string
}

variable "region" {
  description = "AWS region."
  type        = string
}

variable "state_bucket_name" {
  description = "Name of the Terraform state bucket (must match bucket in ../backend.hcl)."
  type        = string
}

variable "noncurrent_version_retention_days" {
  description = "Days a superseded state version is kept."
  type        = number
  default     = 90
}
