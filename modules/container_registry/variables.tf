variable "repository_names" {
  description = "Names of the private ECR repositories to create (e.g. keep/keep-api)."
  type        = set(string)
}

variable "image_retention_count" {
  description = "Number of most recent images kept per repository; older images are expired."
  type        = number
  default     = 30
}
