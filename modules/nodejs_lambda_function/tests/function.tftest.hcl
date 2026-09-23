mock_provider "aws" {
  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
    }
  }
}

variables {
  function_name = "test-dispatcher"
  handler       = "index.dispatcher"
  policy_json   = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
  package_path  = "./tests/fixtures/lambda.zip"
}

run "nodejs_runtime_outside_vpc" {
  command = plan

  assert {
    condition     = aws_lambda_function.main.runtime == "nodejs24.x" && aws_lambda_function.main.architectures == tolist(["arm64"])
    error_message = "Node.js 24 on arm64 expected by default."
  }

  assert {
    condition     = aws_lambda_function.main.environment[0].variables["NODE_OPTIONS"] == "--enable-source-maps"
    error_message = "Source maps must be enabled for readable stack traces."
  }

  assert {
    condition     = contains(keys(aws_iam_role_policy_attachment.managed), "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole")
    error_message = "Basic execution role expected outside a VPC."
  }
}

run "inside_vpc_with_reserved_concurrency" {
  command = plan

  variables {
    reserved_concurrent_executions = 3
    vpc_config = {
      subnet_ids         = ["subnet-1", "subnet-2"]
      security_group_ids = ["sg-1"]
    }
  }

  assert {
    condition     = contains(keys(aws_iam_role_policy_attachment.managed), "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole")
    error_message = "VPC access execution role expected inside a VPC."
  }

  assert {
    condition     = aws_lambda_function.main.reserved_concurrent_executions == 3
    error_message = "Reserved concurrency must be passed through."
  }
}

run "rejects_non_nodejs_runtime" {
  command = plan

  variables {
    runtime = "provided.al2023"
  }

  expect_failures = [var.runtime]
}

run "missing_package_fails_at_plan" {
  command = plan

  variables {
    package_path = "./tests/fixtures/does-not-exist.zip"
  }

  expect_failures = [aws_lambda_function.main]
}
