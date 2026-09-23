output "alarm_topic_arn" {
  description = "ARN of the pipeline alarm topic."
  value       = aws_sns_topic.alarm.arn
}
