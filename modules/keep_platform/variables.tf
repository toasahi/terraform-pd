variable "name" {
  description = "Name prefix of the Keep resources."
  type        = string
}

# --- Network ---------------------------------------------------------------------------------

variable "vpc_id" {
  description = "VPC that hosts Keep."
  type        = string
}

variable "subnet_ids" {
  description = "Private subnets for ECS tasks, the internal ALB, RDS and ElastiCache (at least two AZs)."
  type        = list(string)
}

variable "alb_ingress_cidrs" {
  description = "CIDRs allowed to reach the internal ALB on 443 (the VPC itself, plus VPN / office ranges for the UI)."
  type        = list(string)
}

variable "hosted_zone_id" {
  description = "Route 53 hosted zone for the UI / API records and ACM DNS validation."
  type        = string
}

variable "ui_domain_name" {
  description = "Host name of the Keep UI (e.g. keep.mgmt.example.com)."
  type        = string
}

variable "api_domain_name" {
  description = "Host name of the Keep API (e.g. keep-api.mgmt.example.com). The Dispatcher Lambda posts here."
  type        = string
}

# --- Images ----------------------------------------------------------------------------------

variable "api_image" {
  description = "Keep backend image, pinned by digest (<ecr-repo-url>@sha256:...)."
  type        = string

  validation {
    condition     = can(regex("@sha256:[0-9a-f]{64}$", var.api_image))
    error_message = "api_image must be pinned by digest."
  }
}

variable "ui_image" {
  description = "Keep frontend image, pinned by digest (<ecr-repo-url>@sha256:...)."
  type        = string

  validation {
    condition     = can(regex("@sha256:[0-9a-f]{64}$", var.ui_image))
    error_message = "ui_image must be pinned by digest."
  }
}

variable "cpu_architecture" {
  description = "CPU architecture of the Fargate tasks (X86_64 until an arm64 Keep image is confirmed)."
  type        = string
  default     = "X86_64"
}

# --- Keep API / scheduler --------------------------------------------------------------------

variable "api_desired_count" {
  description = "Number of Keep API tasks."
  type        = number
  default     = 2
}

variable "api_cpu_units" {
  description = "CPU units of a Keep API task (1024 = 1 vCPU)."
  type        = number
  default     = 1024
}

variable "api_memory_mb" {
  description = "Memory of a Keep API task, in MiB."
  type        = number
  default     = 2048
}

variable "enable_dedicated_scheduler" {
  description = <<-EOT
    false: every API task runs the workflow scheduler (Keep default SCHEDULER=true).
    true : API tasks run with SCHEDULER=false and a separate single-task scheduler service runs
           SCHEDULER=true. Switch to true if phase-1 test 6 shows interval workflows running twice.
  EOT
  type        = bool
  default     = false
}

variable "auth_type" {
  description = "Keep AUTH_TYPE (DB, OKTA, KEYCLOAK, OAUTH2PROXY, ...)."
  type        = string
  default     = "DB"
}

variable "keep_limit_concurrency" {
  description = "Keep KEEP_LIMIT_CONCURRENCY for /alerts/event (KEEP_USE_LIMITER is always on)."
  type        = string
  default     = "100/minute"
}

variable "api_extra_environment" {
  description = "Additional plain environment variables for the Keep API container."
  type        = map(string)
  default     = {}
}

variable "api_health_check_path" {
  description = "ALB health check path of the Keep API."
  type        = string
  default     = "/healthcheck"
}

variable "sqs_send_queue_arns" {
  description = "Queues Keep workflows may send to with the amazonsqs provider."
  type        = list(string)
  default     = []
}

# --- Keep UI ---------------------------------------------------------------------------------

variable "ui_desired_count" {
  description = "Number of Keep UI tasks."
  type        = number
  default     = 1
}

variable "ui_cpu_units" {
  description = "CPU units of a Keep UI task."
  type        = number
  default     = 512
}

variable "ui_memory_mb" {
  description = "Memory of a Keep UI task, in MiB."
  type        = number
  default     = 1024
}

# --- Database / cache ------------------------------------------------------------------------

variable "db_instance_class" {
  description = "RDS instance class."
  type        = string
  default     = "db.t4g.medium"
}

variable "db_engine_version" {
  description = "RDS for PostgreSQL major version."
  type        = string
  default     = "17"
}

variable "db_allocated_storage_gb" {
  description = "Initial storage, in GiB."
  type        = number
  default     = 50
}

variable "db_max_allocated_storage_gb" {
  description = "Storage autoscaling ceiling, in GiB."
  type        = number
  default     = 200
}

variable "db_backup_retention_days" {
  description = "Automated backup retention, in days."
  type        = number
  default     = 7
}

variable "cache_node_type" {
  description = "ElastiCache node type of the Valkey replication group (Keep ARQ queue)."
  type        = string
  default     = "cache.t4g.small"
}

variable "cache_engine_version" {
  description = "Valkey engine version."
  type        = string
  default     = "8.0"
}

variable "secret_version" {
  description = "Bump to regenerate the Terraform-generated secrets (DB password, JWT / NextAuth secrets, admin password). Values are write-only and never stored in state."
  type        = number
  default     = 1
}

variable "enable_execute_command" {
  description = "Whether ECS Exec is enabled on the Keep services."
  type        = bool
  default     = false
}

variable "log_retention_days" {
  description = "Retention of container log groups, in days."
  type        = number
  default     = 90
}
