output "alarm_topic_arn" {
  description = "ARN of the pipeline alarm topic."
  value       = aws_sns_topic.alarm.arn
}

output "queue_age_alarms" {
  description = "Oldest-message-age alarms keyed by queue logical name: alarm name, watched queue (QueueName dimension) and threshold in seconds."
  value = {
    for key, alarm in aws_cloudwatch_metric_alarm.queue_age : key => {
      alarm_name = alarm.alarm_name
      queue_name = alarm.dimensions["QueueName"]
      threshold  = alarm.threshold
    }
  }
}

output "dead_letter_alarms" {
  description = "DLQ-not-empty alarms keyed by queue logical name: alarm name and watched DLQ (QueueName dimension)."
  value = {
    for key, alarm in aws_cloudwatch_metric_alarm.dead_letter : key => {
      alarm_name = alarm.alarm_name
      queue_name = alarm.dimensions["QueueName"]
    }
  }
}
