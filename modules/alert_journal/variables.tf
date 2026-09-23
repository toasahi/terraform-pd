variable "table_name" {
  description = "Name of the AlertEventJournal DynamoDB table."
  type        = string
}

variable "kms_key_arn" {
  description = "Customer managed KMS key for server-side encryption. null uses the AWS managed key (aws/dynamodb)."
  type        = string
  default     = null
}

variable "enable_point_in_time_recovery" {
  description = "Whether point-in-time recovery is enabled."
  type        = bool
  default     = true
}
