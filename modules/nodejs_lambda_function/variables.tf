variable "function_name" {
  description = "Name of the Lambda function."
  type        = string
}

variable "description" {
  description = "Description of the Lambda function."
  type        = string
  default     = ""
}

variable "handler" {
  description = "Handler in <file>.<export> form (e.g. index.ingest)."
  type        = string
}

variable "package_path" {
  description = "Path of the local deployment package (zip with index.mjs, built by helpers/build-lambda.sh)."
  type        = string
}

variable "runtime" {
  description = "Lambda Node.js managed runtime."
  type        = string
  default     = "nodejs24.x"

  validation {
    condition     = can(regex("^nodejs[0-9]+\\.x$", var.runtime))
    error_message = "runtime must be a Node.js managed runtime (nodejsNN.x)."
  }
}

variable "architecture" {
  description = "Instruction set architecture (the bundle is pure JavaScript, so both work)."
  type        = string
  default     = "arm64"

  validation {
    condition     = contains(["arm64", "x86_64"], var.architecture)
    error_message = "architecture must be arm64 or x86_64."
  }
}

variable "memory_size_mb" {
  description = "Memory allocated to the function, in MB."
  type        = number
  default     = 512
}

variable "timeout_seconds" {
  description = "Function timeout, in seconds."
  type        = number
  default     = 30
}

variable "reserved_concurrent_executions" {
  description = "Reserved concurrency. null leaves the function unreserved."
  type        = number
  default     = null
}

variable "environment_variables" {
  description = "Environment variables of the function."
  type        = map(string)
  default     = {}
}

variable "policy_json" {
  description = "Inline IAM policy document (JSON) granting the function's own permissions. Required: its value is usually unknown until apply, so it cannot drive count."
  type        = string
}

variable "vpc_config" {
  description = "VPC attachment. null runs the function outside a VPC."
  type = object({
    subnet_ids         = list(string)
    security_group_ids = list(string)
  })
  default = null
}

variable "log_retention_days" {
  description = "Retention of the function's log group, in days."
  type        = number
  default     = 90
}

variable "enable_active_tracing" {
  description = "Whether X-Ray active tracing is enabled."
  type        = bool
  default     = true
}
