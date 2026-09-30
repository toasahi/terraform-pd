data "aws_region" "current" {}

resource "aws_vpc" "main" {
  cidr_block           = var.cidr_block
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = var.name
  }
}

# Deny-all default security group; every workload uses its own security group.
resource "aws_default_security_group" "main" {
  vpc_id = aws_vpc.main.id
}

resource "aws_subnet" "private" {
  for_each = var.private_subnets

  vpc_id            = aws_vpc.main.id
  availability_zone = each.key
  cidr_block        = each.value

  tags = {
    Name = "${var.name}-private-${each.key}"
    Tier = "private"
  }
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "${var.name}-private"
  }
}

# Egress goes through the shared transit gateway to the central egress; this VPC has no IGW, NAT or EIP.
# The network team attaches the VPC to the transit gateway and owns the TGW-side routes.
# The default route exists only when transit_gateway_id is set and an attachment of this VPC to it
# is available (a route to an unattached transit gateway cannot be created).
data "aws_ec2_transit_gateway_vpc_attachments" "main" {
  count = var.transit_gateway_id == null ? 0 : 1

  filter {
    name   = "vpc-id"
    values = [aws_vpc.main.id]
  }

  filter {
    name   = "transit-gateway-id"
    values = [var.transit_gateway_id]
  }

  filter {
    name   = "state"
    values = ["available"]
  }
}

resource "aws_route" "private_default" {
  count = var.transit_gateway_id == null ? 0 : 1

  route_table_id         = aws_route_table.private.id
  destination_cidr_block = "0.0.0.0/0"
  transit_gateway_id     = var.transit_gateway_id

  lifecycle {
    precondition {
      condition     = length(data.aws_ec2_transit_gateway_vpc_attachments.main[0].ids) > 0
      error_message = "No available attachment of this VPC to transit_gateway_id. Ask the network team to attach the VPC to the transit gateway first, or set transit_gateway_id = null."
    }
  }
}

resource "aws_route_table_association" "private" {
  for_each = aws_subnet.private

  subnet_id      = each.value.id
  route_table_id = aws_route_table.private.id
}

resource "aws_vpc_endpoint" "gateway" {
  for_each = var.gateway_endpoint_services

  vpc_id            = aws_vpc.main.id
  service_name      = "com.amazonaws.${data.aws_region.current.region}.${each.key}"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.private.id]

  tags = {
    Name = "${var.name}-${each.key}"
  }
}
