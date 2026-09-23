# Node.js Lambda function (managed runtime) running an esbuild bundle of the TypeScript / Effect
# handlers in lambda/. All functions of the pipeline share one bundle and differ only in handler.

data "aws_iam_policy_document" "assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "main" {
  name               = var.function_name
  assume_role_policy = data.aws_iam_policy_document.assume.json
}

resource "aws_iam_role_policy" "main" {
  role   = aws_iam_role.main.id
  policy = var.policy_json
}

locals {
  # Guarded so that static analysis (validate / tflint) works before the package is built; the
  # precondition on the function turns a missing package into a clear plan-time error.
  package_exists = fileexists(var.package_path)
  package_hash   = local.package_exists ? filebase64sha256(var.package_path) : null

  managed_policy_arns = concat(
    [var.vpc_config == null ? "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole" : "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"],
    var.enable_active_tracing ? ["arn:aws:iam::aws:policy/AWSXRayDaemonWriteAccess"] : [],
  )
}

resource "aws_iam_role_policy_attachment" "managed" {
  for_each = toset(local.managed_policy_arns)

  role       = aws_iam_role.main.name
  policy_arn = each.value
}

resource "aws_cloudwatch_log_group" "main" {
  name              = "/aws/lambda/${var.function_name}"
  retention_in_days = var.log_retention_days
}

resource "aws_lambda_function" "main" {
  function_name = var.function_name
  description   = var.description
  role          = aws_iam_role.main.arn

  runtime       = var.runtime
  handler       = var.handler
  architectures = [var.architecture]

  filename         = var.package_path
  source_code_hash = local.package_hash

  memory_size                    = var.memory_size_mb
  timeout                        = var.timeout_seconds
  reserved_concurrent_executions = var.reserved_concurrent_executions

  environment {
    variables = merge({ NODE_OPTIONS = "--enable-source-maps" }, var.environment_variables)
  }

  dynamic "vpc_config" {
    for_each = var.vpc_config == null ? [] : [var.vpc_config]

    content {
      subnet_ids         = vpc_config.value.subnet_ids
      security_group_ids = vpc_config.value.security_group_ids
    }
  }

  tracing_config {
    mode = var.enable_active_tracing ? "Active" : "PassThrough"
  }

  logging_config {
    log_format = "JSON"
    log_group  = aws_cloudwatch_log_group.main.name
  }

  depends_on = [aws_iam_role_policy_attachment.managed]

  lifecycle {
    precondition {
      condition     = local.package_exists
      error_message = "Lambda package ${var.package_path} not found. Build it first: helpers/build-lambda.sh"
    }
  }
}
