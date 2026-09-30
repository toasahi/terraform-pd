# Long-lived shared foundation: the VPC that hosts Keep and the Dispatcher Lambda, and the private
# ECR repositories that the Keep images are mirrored into (they must exist before the keep root).

module "network" {
  source = "../../../../modules/network"

  name               = var.name
  cidr_block         = var.vpc_cidr_block
  private_subnets    = var.private_subnets
  transit_gateway_id = var.transit_gateway_id
}

module "container_registry" {
  source = "../../../../modules/container_registry"

  repository_names = ["keep/keep-api", "keep/keep-ui"]
}
