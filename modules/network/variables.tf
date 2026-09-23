variable "name" {
  description = "Name prefix for the VPC and its resources."
  type        = string
}

variable "cidr_block" {
  description = "IPv4 CIDR block of the VPC."
  type        = string
}

variable "private_subnets" {
  description = "Private subnets keyed by availability zone name (e.g. ap-northeast-1a = 10.0.0.0/20)."
  type        = map(string)

  validation {
    condition     = length(var.private_subnets) >= 2
    error_message = "At least two availability zones are required."
  }
}

variable "enable_flow_logs" {
  description = "Whether to send VPC flow logs to CloudWatch Logs."
  type        = bool
  default     = true
}

variable "flow_log_retention_days" {
  description = "Retention of the VPC flow log group, in days."
  type        = number
  default     = 90
}

variable "gateway_endpoint_services" {
  description = "Services that get a (free) gateway VPC endpoint attached to the private route table."
  type        = set(string)
  default     = ["s3", "dynamodb"]
}
