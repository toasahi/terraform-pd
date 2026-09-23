variable "name" {
  description = "Name prefix of the alarms and the alarm topic."
  type        = string
}

variable "alarm_email_endpoints" {
  description = "E-mail addresses subscribed to the pipeline alarm topic (confirmation required)."
  type        = list(string)
  default     = []
}

variable "queues" {
  description = "Main FIFO queues keyed by logical name, with the oldest-message age that raises an alarm."
  type = map(object({
    queue_name                 = string
    max_oldest_message_seconds = number
  }))
}

variable "dead_letter_queue_names" {
  description = "Dead-letter queues keyed by logical name; any visible message raises an alarm."
  type        = map(string)
}

variable "lambda_function_names" {
  description = "Lambda functions keyed by role; any error raises an alarm."
  type        = map(string)
}

variable "throttle_watched_functions" {
  description = "Roles (keys of lambda_function_names) whose throttles raise an alarm."
  type        = set(string)
  default     = []
}

variable "api" {
  description = "REST API to watch. Any 4XX is an alarm too: Alertmanager never retries 4xx, so each one is a lost notification."
  type = object({
    api_name   = string
    stage_name = string
  })
}

variable "web_acl_name" {
  description = "WAF web ACL whose blocked requests raise an alarm."
  type        = string
}

variable "ecs_services" {
  description = "ECS services keyed by role, with the minimum number of running tasks."
  type = map(object({
    cluster_name      = string
    service_name      = string
    min_running_tasks = number
  }))
  default = {}
}

variable "period_seconds" {
  description = "Evaluation period of the alarms, in seconds."
  type        = number
  default     = 60
}
