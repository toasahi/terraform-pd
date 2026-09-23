output "function_name" {
  description = "Name of the Lambda function."
  value       = aws_lambda_function.main.function_name
}

output "function_arn" {
  description = "ARN of the Lambda function."
  value       = aws_lambda_function.main.arn
}

output "invoke_arn" {
  description = "Invoke ARN used by API Gateway integrations and authorizers."
  value       = aws_lambda_function.main.invoke_arn
}

output "role_name" {
  description = "Name of the execution role."
  value       = aws_iam_role.main.name
}

output "role_arn" {
  description = "ARN of the execution role."
  value       = aws_iam_role.main.arn
}

output "log_group_name" {
  description = "Name of the function's log group."
  value       = aws_cloudwatch_log_group.main.name
}
