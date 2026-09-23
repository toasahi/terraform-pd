data "aws_route53_zone" "public" {
  name         = var.public_zone_name
  private_zone = false
}

module "ingress" {
  source = "../../../../modules/alert_ingress"

  name           = "${local.name}-ingest"
  domain_name    = "alerts.${var.public_zone_name}"
  hosted_zone_id = data.aws_route53_zone.public.zone_id

  allowed_source_cidrs = distinct(flatten([for source in values(var.alert_sources) : source.egress_cidrs]))

  authorizer_function = {
    function_name = module.authorizer.function_name
    invoke_arn    = module.authorizer.invoke_arn
  }

  ingest_function = {
    function_name = module.ingest.function_name
    invoke_arn    = module.ingest.invoke_arn
  }
}

# Account/region-wide API Gateway setting required for stage access and execution logging.
# Only one configuration may manage it per account and region.
data "aws_iam_policy_document" "apigateway_assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["apigateway.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "apigateway_cloudwatch" {
  name               = "apigateway-cloudwatch-logs-${var.region}"
  assume_role_policy = data.aws_iam_policy_document.apigateway_assume.json
}

resource "aws_iam_role_policy_attachment" "apigateway_cloudwatch" {
  role       = aws_iam_role.apigateway_cloudwatch.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonAPIGatewayPushToCloudWatchLogs"
}

resource "aws_api_gateway_account" "main" {
  cloudwatch_role_arn = aws_iam_role.apigateway_cloudwatch.arn

  depends_on = [aws_iam_role_policy_attachment.apigateway_cloudwatch]
}
