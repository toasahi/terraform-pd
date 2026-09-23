output "endpoint_url" {
  description = "Base URL for Alertmanager webhook_config (append the source name)."
  value       = "https://${aws_api_gateway_domain_name.main.domain_name}/v1/alerts/"
}

output "rest_api_id" {
  description = "ID of the REST API."
  value       = aws_api_gateway_rest_api.main.id
}

output "rest_api_name" {
  description = "Name of the REST API (CloudWatch ApiName dimension)."
  value       = aws_api_gateway_rest_api.main.name
}

output "stage_name" {
  description = "Name of the stage."
  value       = aws_api_gateway_stage.main.stage_name
}

output "stage_arn" {
  description = "ARN of the stage."
  value       = aws_api_gateway_stage.main.arn
}

output "web_acl_name" {
  description = "Name of the WAF web ACL."
  value       = aws_wafv2_web_acl.main.name
}

output "web_acl_arn" {
  description = "ARN of the WAF web ACL."
  value       = aws_wafv2_web_acl.main.arn
}

output "regional_domain_name" {
  description = "Regional target domain of the custom domain (for phase-3 failover records)."
  value       = aws_api_gateway_domain_name.main.regional_domain_name
}

output "regional_zone_id" {
  description = "Hosted zone ID of the regional target domain."
  value       = aws_api_gateway_domain_name.main.regional_zone_id
}
