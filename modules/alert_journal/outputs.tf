output "table_name" {
  description = "Name of the journal table."
  value       = aws_dynamodb_table.main.name
}

output "table_arn" {
  description = "ARN of the journal table."
  value       = aws_dynamodb_table.main.arn
}

output "stream_arn" {
  description = "ARN of the journal table stream."
  value       = aws_dynamodb_table.main.stream_arn
}
