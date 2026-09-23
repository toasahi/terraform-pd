variable "name_prefix" {
  description = "Prefix of the queue names (<prefix>-<key>.fifo)."
  type        = string
}

variable "queues" {
  description = <<-EOT
    FIFO queues keyed by logical name (underscores become hyphens in the queue name).
    visibility_timeout_seconds must be at least 6x the consumer Lambda timeout.
  EOT
  type = map(object({
    visibility_timeout_seconds = number
    max_receive_count          = optional(number, 5)
    message_retention_seconds  = optional(number, 1209600)
  }))
}

variable "kms_master_key_id" {
  description = "KMS key for SSE-KMS. null uses SQS managed server-side encryption (SSE-SQS)."
  type        = string
  default     = null
}
