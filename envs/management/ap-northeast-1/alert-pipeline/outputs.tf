output "ingest_endpoint_url" {
  description = "Base URL for Alertmanager webhook_config; append the source name (e.g. .../v1/alerts/prod)."
  value       = module.ingress.endpoint_url
}

output "source_tokens_secret_arn" {
  description = "Secret holding the per-source token digests (value set by an operator)."
  value       = aws_secretsmanager_secret.source_tokens.arn
}

output "journal_table_name" {
  description = "AlertEventJournal table name."
  value       = module.journal.table_name
}

output "queue_urls" {
  description = "FIFO queue URLs keyed by logical name."
  value       = module.queues.queue_urls
}

output "critical_topic_arn" {
  description = "SNS topic for Keep-independent critical notifications."
  value       = aws_sns_topic.critical.arn
}

output "alarm_topic_arn" {
  description = "SNS topic of the pipeline's own alarms."
  value       = module.monitoring.alarm_topic_arn
}
