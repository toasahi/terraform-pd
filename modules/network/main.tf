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

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = var.name
  }
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

# Regional NAT Gateway: one gateway for the whole VPC that spans AZs (no public subnets needed).
# The Elastic IPs are pinned per AZ (manual mode) so that the egress addresses are stable and can be
# registered in allow-lists of external services.
resource "aws_eip" "nat" {
  for_each = var.private_subnets

  domain = "vpc"

  tags = {
    Name = "${var.name}-nat-${each.key}"
  }
}

resource "aws_nat_gateway" "main" {
  vpc_id            = aws_vpc.main.id
  availability_mode = "regional"
  connectivity_type = "public"

  dynamic "availability_zone_address" {
    for_each = aws_eip.nat

    content {
      availability_zone = availability_zone_address.key
      allocation_ids    = [availability_zone_address.value.allocation_id]
    }
  }

  tags = {
    Name = var.name
  }

  depends_on = [aws_internet_gateway.main]
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "${var.name}-private"
  }
}

resource "aws_route" "private_default" {
  route_table_id         = aws_route_table.private.id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.main.id
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
