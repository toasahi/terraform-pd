data "aws_region" "current" {}

data "aws_caller_identity" "current" {}

locals {
  region     = data.aws_region.current.region
  account_id = data.aws_caller_identity.current.account_id

  api_url = "https://${var.api_domain_name}"
  ui_url  = "https://${var.ui_domain_name}"

  api_port = 8080
  ui_port  = 3000

  # Environment shared by every Keep backend task (API and scheduler).
  backend_environment = merge(
    {
      PORT                   = tostring(local.api_port)
      KEEP_API_URL           = local.api_url
      AUTH_TYPE              = var.auth_type
      SECRET_MANAGER_TYPE    = "AWS"
      AWS_REGION             = local.region
      REDIS                  = "true"
      REDIS_HOST             = aws_elasticache_replication_group.main.primary_endpoint_address
      REDIS_PORT             = "6379"
      KEEP_USE_LIMITER       = "true"
      KEEP_LIMIT_CONCURRENCY = var.keep_limit_concurrency
      # Push only: pulling defaults to every 7 days and bypasses workflows.
      KEEP_PULL_DATA_ENABLED = "false"
      CONSUMER               = "true"
    },
    var.api_extra_environment,
  )

  backend_secrets = {
    DATABASE_CONNECTION_STRING = aws_secretsmanager_secret.generated["database-connection-string"].arn
    KEEP_JWT_SECRET            = aws_secretsmanager_secret.generated["jwt-secret"].arn
    KEEP_DEFAULT_PASSWORD      = aws_secretsmanager_secret.generated["admin-password"].arn
  }

  ui_environment = {
    API_URL      = local.api_url
    NEXTAUTH_URL = local.ui_url
    AUTH_TYPE    = var.auth_type
  }

  ui_secrets = {
    NEXTAUTH_SECRET = aws_secretsmanager_secret.generated["nextauth-secret"].arn
  }
}

resource "aws_ecs_cluster" "main" {
  name = var.name

  setting {
    name  = "containerInsights"
    value = "enhanced"
  }
}

resource "aws_ecs_cluster_capacity_providers" "main" {
  cluster_name       = aws_ecs_cluster.main.name
  capacity_providers = ["FARGATE"]

  default_capacity_provider_strategy {
    capacity_provider = "FARGATE"
    weight            = 1
  }
}
