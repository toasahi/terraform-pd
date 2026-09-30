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

  # Apply-mode runs need valid ARNs: random mock values fail aws_flow_log validation.
  mock_resource "aws_cloudwatch_log_group" {
    defaults = {
      arn = "arn:aws:logs:ap-northeast-1:123456789012:log-group:/vpc/test/flow-logs"
    }
  }

  mock_resource "aws_iam_role" {
    defaults = {
      arn = "arn:aws:iam::123456789012:role/test-vpc-flow-logs"
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
  transit_gateway_id = "tgw-0123456789abcdef0"
}

# The network team has attached the VPC to the shared transit gateway.
override_data {
  target = data.aws_ec2_transit_gateway_vpc_attachments.main
  values = {
    ids = ["tgw-attach-0123456789abcdef0"]
  }
}

run "default_route_via_transit_gateway" {
  command = apply

  assert {
    condition     = aws_route.private_default[0].transit_gateway_id == var.transit_gateway_id
    error_message = "The private default route must target the shared transit gateway."
  }

  assert {
    condition     = aws_route.private_default[0].destination_cidr_block == "0.0.0.0/0"
    error_message = "The transit gateway route must be the default route."
  }

  assert {
    condition     = aws_route.private_default[0].nat_gateway_id == null
    error_message = "The default route must not use a NAT gateway."
  }

  # override_data ignores filters, so the precondition alone cannot prove the lookup's scope.
  assert {
    condition = toset([
      for f in data.aws_ec2_transit_gateway_vpc_attachments.main[0].filter : "${f.name}=${join(",", f.values)}"
      ]) == toset([
      "vpc-id=${aws_vpc.main.id}",
      "transit-gateway-id=${var.transit_gateway_id}",
      "state=available",
    ])
    error_message = "The attachment lookup must be scoped to this VPC, this transit gateway and state = available."
  }

  assert {
    condition     = length(aws_subnet.private) == 2
    error_message = "One private subnet per AZ expected."
  }

  assert {
    condition     = aws_vpc_endpoint.gateway["dynamodb"].service_name == "com.amazonaws.ap-northeast-1.dynamodb"
    error_message = "DynamoDB gateway endpoint expected."
  }

  assert {
    condition = alltrue([
      for service in ["s3", "dynamodb"] :
      contains(aws_vpc_endpoint.gateway[service].route_table_ids, aws_route_table.private.id)
    ])
    error_message = "The S3 and DynamoDB gateway endpoints must stay on the private route table."
  }
}

run "no_default_route_until_attached" {
  command = plan

  variables {
    transit_gateway_id = null
  }

  assert {
    condition     = length(aws_route.private_default) == 0
    error_message = "No default route may exist before the transit gateway ID is set."
  }

  assert {
    condition     = length(data.aws_ec2_transit_gateway_vpc_attachments.main) == 0
    error_message = "The attachment lookup must be skipped while the transit gateway ID is null."
  }
}

run "rejects_route_without_available_attachment" {
  command = apply
  # A separate state: with the shared state (or plan mode) the lookup is deferred until the VPC exists.
  state_key = "unattached"

  override_data {
    target = data.aws_ec2_transit_gateway_vpc_attachments.main
    values = {
      ids = []
    }
  }

  expect_failures = [aws_route.private_default]
}

run "rejects_malformed_transit_gateway_id" {
  command = plan

  variables {
    transit_gateway_id = "nat-0123456789abcdef0"
  }

  expect_failures = [var.transit_gateway_id]
}

run "rejects_single_az" {
  command = plan

  variables {
    private_subnets = { "ap-northeast-1a" = "10.40.0.0/22" }
  }

  expect_failures = [var.private_subnets]
}
