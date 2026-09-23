output "queue_urls" {
  description = "Queue URLs keyed by logical name."
  value       = { for key, queue in aws_sqs_queue.main : key => queue.url }
}

output "queue_arns" {
  description = "Queue ARNs keyed by logical name."
  value       = { for key, queue in aws_sqs_queue.main : key => queue.arn }
}

output "queue_names" {
  description = "Queue names keyed by logical name."
  value       = { for key, queue in aws_sqs_queue.main : key => queue.name }
}

output "dead_letter_queue_names" {
  description = "Dead-letter queue names keyed by logical name."
  value       = { for key, queue in aws_sqs_queue.dead_letter : key => queue.name }
}

output "dead_letter_queue_arns" {
  description = "Dead-letter queue ARNs keyed by logical name."
  value       = { for key, queue in aws_sqs_queue.dead_letter : key => queue.arn }
}
