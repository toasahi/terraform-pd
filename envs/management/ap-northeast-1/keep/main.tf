data "terraform_remote_state" "foundation" {
  backend = "s3"

  config = {
    bucket = var.state_bucket_name
    key    = "management/ap-northeast-1/foundation.tfstate"
    region = var.region
  }
}

data "aws_route53_zone" "public" {
  name         = var.public_zone_name
  private_zone = false
}

locals {
  foundation = data.terraform_remote_state.foundation.outputs
}

module "keep_platform" {
  source = "../../../../modules/keep_platform"

  name       = "keep"
  vpc_id     = local.foundation.vpc_id
  subnet_ids = local.foundation.private_subnet_ids
  # The VPC itself (Dispatcher Lambda) plus operator networks for the UI.
  alb_ingress_cidrs = concat([local.foundation.vpc_cidr_block], var.operator_cidrs)

  hosted_zone_id  = data.aws_route53_zone.public.zone_id
  ui_domain_name  = "keep.${var.public_zone_name}"
  api_domain_name = "keep-api.${var.public_zone_name}"

  api_image = "${local.foundation.repository_urls["keep/keep-api"]}@${var.keep_api_image_digest}"
  ui_image  = "${local.foundation.repository_urls["keep/keep-ui"]}@${var.keep_ui_image_digest}"

  api_desired_count          = var.api_desired_count
  enable_dedicated_scheduler = var.enable_dedicated_scheduler
  keep_limit_concurrency     = var.keep_limit_concurrency
}
