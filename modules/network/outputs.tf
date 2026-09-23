output "vpc_id" {
  description = "ID of the VPC."
  value       = aws_vpc.main.id
}

output "vpc_cidr_block" {
  description = "IPv4 CIDR block of the VPC."
  value       = aws_vpc.main.cidr_block
}

output "private_subnet_ids" {
  description = "IDs of the private subnets, in availability zone order."
  value       = [for az in sort(keys(aws_subnet.private)) : aws_subnet.private[az].id]
}

output "private_route_table_id" {
  description = "ID of the private route table."
  value       = aws_route_table.private.id
}

output "nat_gateway_id" {
  description = "ID of the Regional NAT Gateway."
  value       = aws_nat_gateway.main.id
}

output "nat_public_ips" {
  description = "Egress public IPs of the Regional NAT Gateway (one per AZ)."
  value       = [for az in sort(keys(aws_eip.nat)) : aws_eip.nat[az].public_ip]
}
