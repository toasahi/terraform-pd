mock_provider "aws" {
  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
    }
  }

  mock_data "aws_region" {
    defaults = {
      region = "ap-northeast-1"
    }
  }
}

variables {
  name       = "test"
  cidr_block = "10.40.0.0/20"
  private_subnets = {
    "ap-northeast-1a" = "10.40.0.0/22"
    "ap-northeast-1c" = "10.40.4.0/22"
  }
}

run "regional_nat_with_pinned_eips" {
  command = plan

  assert {
    condition     = aws_nat_gateway.main.availability_mode == "regional"
    error_message = "NAT gateway must be regional."
  }

  assert {
    condition     = length(aws_eip.nat) == 2 && length(aws_subnet.private) == 2
    error_message = "One EIP and one private subnet per AZ expected."
  }

  assert {
    condition     = aws_vpc_endpoint.gateway["dynamodb"].service_name == "com.amazonaws.ap-northeast-1.dynamodb"
    error_message = "DynamoDB gateway endpoint expected."
  }
}

run "rejects_single_az" {
  command = plan

  variables {
    private_subnets = { "ap-northeast-1a" = "10.40.0.0/22" }
  }

  expect_failures = [var.private_subnets]
}
