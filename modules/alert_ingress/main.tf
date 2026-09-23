# Ingest endpoint: API Gateway REST API (Regional). REST, not HTTP API, because only REST API
# stages can be associated with an AWS WAF web ACL (architecture review v4, finding 3.1).
#
#   POST https://<domain_name>/v1/alerts/{source}
#     -> REQUEST authorizer (per-source bearer token) -> ingest Lambda (proxy integration)

resource "aws_api_gateway_rest_api" "main" {
  name        = var.name
  description = "Alert ingest endpoint (Alertmanager webhooks)"

  # Only the custom domain is reachable, so the URL senders use never changes.
  disable_execute_api_endpoint = true

  endpoint_configuration {
    types = ["REGIONAL"]
  }

  lifecycle {
    create_before_destroy = true
  }
}

data "aws_iam_policy_document" "resource_policy" {
  statement {
    effect    = "Allow"
    actions   = ["execute-api:Invoke"]
    resources = ["${aws_api_gateway_rest_api.main.execution_arn}/*"]

    principals {
      type        = "*"
      identifiers = ["*"]
    }
  }

  # Defence in depth next to the WAF IP set.
  statement {
    effect    = "Deny"
    actions   = ["execute-api:Invoke"]
    resources = ["${aws_api_gateway_rest_api.main.execution_arn}/*"]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    condition {
      test     = "NotIpAddress"
      variable = "aws:SourceIp"
      values   = var.allowed_source_cidrs
    }
  }
}

resource "aws_api_gateway_rest_api_policy" "main" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  policy      = data.aws_iam_policy_document.resource_policy.json
}

resource "aws_api_gateway_resource" "version" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  parent_id   = aws_api_gateway_rest_api.main.root_resource_id
  path_part   = "v1"
}

resource "aws_api_gateway_resource" "alerts" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  parent_id   = aws_api_gateway_resource.version.id
  path_part   = "alerts"
}

resource "aws_api_gateway_resource" "source" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  parent_id   = aws_api_gateway_resource.alerts.id
  path_part   = "{source}"
}

resource "aws_api_gateway_authorizer" "main" {
  name                             = "${var.name}-source-token"
  rest_api_id                      = aws_api_gateway_rest_api.main.id
  type                             = "REQUEST"
  authorizer_uri                   = var.authorizer_function.invoke_arn
  identity_source                  = "method.request.header.Authorization"
  authorizer_result_ttl_in_seconds = var.authorizer_result_ttl_seconds
}

resource "aws_api_gateway_method" "post_alerts" {
  rest_api_id   = aws_api_gateway_rest_api.main.id
  resource_id   = aws_api_gateway_resource.source.id
  http_method   = "POST"
  authorization = "CUSTOM"
  authorizer_id = aws_api_gateway_authorizer.main.id

  request_parameters = {
    "method.request.path.source" = true
  }
}

resource "aws_api_gateway_integration" "post_alerts" {
  rest_api_id             = aws_api_gateway_rest_api.main.id
  resource_id             = aws_api_gateway_resource.source.id
  http_method             = aws_api_gateway_method.post_alerts.http_method
  type                    = "AWS_PROXY"
  integration_http_method = "POST"
  uri                     = var.ingest_function.invoke_arn
}

resource "aws_lambda_permission" "authorizer" {
  statement_id  = "AllowApiGatewayAuthorizer"
  action        = "lambda:InvokeFunction"
  function_name = var.authorizer_function.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_api_gateway_rest_api.main.execution_arn}/authorizers/${aws_api_gateway_authorizer.main.id}"
}

resource "aws_lambda_permission" "ingest" {
  statement_id  = "AllowApiGatewayIngest"
  action        = "lambda:InvokeFunction"
  function_name = var.ingest_function.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_api_gateway_rest_api.main.execution_arn}/*/POST/v1/alerts/*"
}

resource "aws_api_gateway_deployment" "main" {
  rest_api_id = aws_api_gateway_rest_api.main.id

  triggers = {
    redeployment = sha1(jsonencode([
      aws_api_gateway_resource.source,
      aws_api_gateway_authorizer.main,
      aws_api_gateway_method.post_alerts,
      aws_api_gateway_integration.post_alerts,
      aws_api_gateway_rest_api_policy.main.policy,
    ]))
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_cloudwatch_log_group" "access_log" {
  name              = "/aws/apigateway/${var.name}/access"
  retention_in_days = var.log_retention_days
}

resource "aws_api_gateway_stage" "main" {
  rest_api_id          = aws_api_gateway_rest_api.main.id
  deployment_id        = aws_api_gateway_deployment.main.id
  stage_name           = var.stage_name
  xray_tracing_enabled = true

  access_log_settings {
    destination_arn = aws_cloudwatch_log_group.access_log.arn
    format = jsonencode({
      requestId          = "$context.requestId"
      ip                 = "$context.identity.sourceIp"
      requestTime        = "$context.requestTime"
      httpMethod         = "$context.httpMethod"
      resourcePath       = "$context.resourcePath"
      path               = "$context.path"
      status             = "$context.status"
      responseLength     = "$context.responseLength"
      principalId        = "$context.authorizer.principalId"
      authorizerStatus   = "$context.authorizer.status"
      authorizerError    = "$context.authorizer.error"
      integrationStatus  = "$context.integration.status"
      integrationLatency = "$context.integration.latency"
      wafResponseCode    = "$context.wafResponseCode"
      webAclArn          = "$context.webaclArn"
    })
  }
}

resource "aws_api_gateway_method_settings" "all" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  stage_name  = aws_api_gateway_stage.main.stage_name
  method_path = "*/*"

  settings {
    metrics_enabled        = true
    logging_level          = "ERROR"
    data_trace_enabled     = false
    throttling_rate_limit  = var.throttling_rate_limit_rps
    throttling_burst_limit = var.throttling_burst_limit
  }
}
