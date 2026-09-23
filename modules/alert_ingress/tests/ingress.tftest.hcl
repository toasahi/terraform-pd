mock_provider "aws" {
  override_during = plan

  mock_resource "aws_acm_certificate" {
    defaults = {
      domain_validation_options = [{
        domain_name           = "alerts.mgmt.example.com"
        resource_record_name  = "_x.alerts.mgmt.example.com."
        resource_record_type  = "CNAME"
        resource_record_value = "_y.acm-validations.aws."
      }]
    }
  }

  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
    }
  }

  mock_resource "aws_api_gateway_rest_api" {
    defaults = {
      execution_arn = "arn:aws:execute-api:ap-northeast-1:111111111111:abc123"
    }
  }
}

variables {
  name                 = "alert-pipeline-ingest"
  domain_name          = "alerts.mgmt.example.com"
  hosted_zone_id       = "Z123"
  allowed_source_cidrs = ["198.51.100.10/32", "203.0.113.10/32"]
  authorizer_function  = { function_name = "authorizer", invoke_arn = "arn:aws:apigateway:ap-northeast-1:lambda:path/authorizer" }
  ingest_function      = { function_name = "ingest", invoke_arn = "arn:aws:apigateway:ap-northeast-1:lambda:path/ingest" }
}

run "rest_api_behind_waf_allow_list" {
  command = plan

  assert {
    condition     = aws_api_gateway_rest_api.main.endpoint_configuration[0].types == tolist(["REGIONAL"]) && aws_api_gateway_rest_api.main.disable_execute_api_endpoint
    error_message = "Regional REST API reachable only through the custom domain expected."
  }

  assert {
    condition     = length(aws_wafv2_web_acl.main.default_action[0].block) == 1
    error_message = "WAF default action must be block."
  }

  assert {
    condition     = toset(aws_wafv2_ip_set.allowed_sources.addresses) == toset(var.allowed_source_cidrs)
    error_message = "IP set must contain exactly the allowed sources."
  }

  assert {
    condition     = aws_api_gateway_authorizer.main.type == "REQUEST" && aws_api_gateway_method.post_alerts.authorization == "CUSTOM"
    error_message = "POST must use the REQUEST authorizer."
  }

  assert {
    condition     = aws_lambda_permission.ingest.source_arn == "arn:aws:execute-api:ap-northeast-1:111111111111:abc123/*/POST/v1/alerts/*"
    error_message = "Ingest permission must be scoped to POST /v1/alerts/*."
  }
}

run "false_positive_prone_rules_only_count_by_default" {
  command = plan

  assert {
    condition = alltrue([
      for r in aws_wafv2_web_acl.main.rule : length(r.override_action) == 0 || length(r.override_action[0].count) == 1
    ])
    error_message = "Managed rule groups must run in COUNT mode by default."
  }

  assert {
    condition = anytrue([
      for r in aws_wafv2_web_acl.main.rule : r.name == "rate-limit-per-ip" && length(r.action[0].count) == 1
    ])
    error_message = "Rate-based rule must count (not block) by default: Alertmanager does not retry 403."
  }
}

run "rejects_empty_allow_list" {
  command = plan

  variables {
    allowed_source_cidrs = []
  }

  expect_failures = [var.allowed_source_cidrs]
}
