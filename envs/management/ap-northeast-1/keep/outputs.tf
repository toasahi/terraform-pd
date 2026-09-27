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

output "non_critical_inhouse_queue_arn" {
  description = "ARN of the non-critical queue (event source of the in-house notifier Lambda)."
  value       = module.notification_queues.queue_arns["non_critical_inhouse"]
}

output "non_critical_inhouse_queue_url" {
  description = "URL of the non-critical queue (sqs_queue_url of Keep's amazonsqs provider)."
  value       = module.notification_queues.queue_urls["non_critical_inhouse"]
}

output "non_critical_inhouse_queue_name" {
  description = "Name of the non-critical queue (alarm dimension in alert-pipeline)."
  value       = module.notification_queues.queue_names["non_critical_inhouse"]
}

output "non_critical_inhouse_dead_letter_queue_name" {
  description = "Name of the non-critical queue's DLQ (alarm dimension in alert-pipeline)."
  value       = module.notification_queues.dead_letter_queue_names["non_critical_inhouse"]
}
