output "api_url" {
  description = "HTTPS base URL of the Keep API (internal ALB)."
  value       = "https://${aws_route53_record.endpoint[var.api_domain_name].fqdn}"
}

output "ui_url" {
  description = "HTTPS URL of the Keep UI (internal ALB)."
  value       = "https://${aws_route53_record.endpoint[var.ui_domain_name].fqdn}"
}

output "api_key_secret_arn" {
  description = "Secret holding the Keep API key the Dispatcher Lambda uses."
  value       = aws_secretsmanager_secret.api_key.arn
}

output "alb_security_group_id" {
  description = "Security group of the internal ALB."
  value       = aws_security_group.alb.id
}

output "cluster_name" {
  description = "Name of the ECS cluster."
  value       = aws_ecs_cluster.main.name
}

output "service_names" {
  description = "ECS service names keyed by role (api, ui and, when enabled, scheduler)."
  value = merge(
    { for key, service in aws_ecs_service.backend : key => service.name },
    { ui = aws_ecs_service.ui.name },
  )
}

output "service_desired_counts" {
  description = "Desired task counts keyed by role (for running-task alarms)."
  value = merge(
    { for key, service in aws_ecs_service.backend : key => service.desired_count },
    { ui = aws_ecs_service.ui.desired_count },
  )
}

output "db_instance_identifier" {
  description = "Identifier of the RDS instance (phase 3: cross-region read replica source)."
  value       = aws_db_instance.main.identifier
}

output "db_instance_arn" {
  description = "ARN of the RDS instance."
  value       = aws_db_instance.main.arn
}

output "cache_replication_group_id" {
  description = "ID of the ElastiCache replication group."
  value       = aws_elasticache_replication_group.main.id
}
