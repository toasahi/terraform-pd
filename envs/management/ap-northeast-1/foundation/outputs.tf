output "vpc_id" {
  description = "ID of the VPC."
  value       = module.network.vpc_id
}

output "vpc_cidr_block" {
  description = "IPv4 CIDR block of the VPC."
  value       = module.network.vpc_cidr_block
}

output "private_subnet_ids" {
  description = "IDs of the private subnets."
  value       = module.network.private_subnet_ids
}

output "nat_public_ips" {
  description = "Egress public IPs of the VPC (Regional NAT Gateway)."
  value       = module.network.nat_public_ips
}

output "repository_urls" {
  description = "ECR repository URLs keyed by repository name."
  value       = module.container_registry.repository_urls
}
