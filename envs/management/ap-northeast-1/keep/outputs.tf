output "api_url" {
  description = "Keep API base URL (Dispatcher target)."
  value       = module.keep_platform.api_url
}

output "ui_url" {
  description = "Keep UI URL."
  value       = module.keep_platform.ui_url
}

output "api_key_secret_arn" {
  description = "Secret holding the Keep API key for the Dispatcher (value set manually)."
  value       = module.keep_platform.api_key_secret_arn
}

output "cluster_name" {
  description = "ECS cluster name."
  value       = module.keep_platform.cluster_name
}

output "service_names" {
  description = "ECS service names keyed by role."
  value       = module.keep_platform.service_names
}

output "service_desired_counts" {
  description = "Desired task counts keyed by role."
  value       = module.keep_platform.service_desired_counts
}

output "db_instance_identifier" {
  description = "RDS instance identifier."
  value       = module.keep_platform.db_instance_identifier
}
