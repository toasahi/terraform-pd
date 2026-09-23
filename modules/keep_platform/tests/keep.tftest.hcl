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

  mock_data "aws_caller_identity" {
    defaults = {
      account_id = "111111111111"
    }
  }

  mock_resource "aws_db_instance" {
    defaults = {
      address  = "keep.cluster.ap-northeast-1.rds.amazonaws.com"
      port     = 5432
      username = "keep"
      db_name  = "keep"
    }
  }
}

override_resource {
  target          = aws_acm_certificate.main
  override_during = plan
  values = {
    arn = "arn:aws:acm:ap-northeast-1:111111111111:certificate/keep"
    domain_validation_options = [
      {
        domain_name           = "keep.mgmt.example.com"
        resource_record_name  = "_a.keep.mgmt.example.com."
        resource_record_type  = "CNAME"
        resource_record_value = "_b.acm-validations.aws."
      },
      {
        domain_name           = "keep-api.mgmt.example.com"
        resource_record_name  = "_c.keep-api.mgmt.example.com."
        resource_record_type  = "CNAME"
        resource_record_value = "_d.acm-validations.aws."
      },
    ]
  }
}

override_resource {
  target          = aws_elasticache_replication_group.main
  override_during = plan
  values = {
    primary_endpoint_address = "keep.cache.apne1.cache.amazonaws.com"
  }
}

override_resource {
  target          = aws_secretsmanager_secret.generated
  override_during = plan
  values = {
    arn = "arn:aws:secretsmanager:ap-northeast-1:111111111111:secret:keep/generated"
  }
}

# The real (offline) random provider: mock providers cannot serve ephemeral resources.

variables {
  name              = "keep"
  vpc_id            = "vpc-1"
  subnet_ids        = ["subnet-1", "subnet-2"]
  alb_ingress_cidrs = ["10.40.0.0/20"]
  hosted_zone_id    = "Z123"
  ui_domain_name    = "keep.mgmt.example.com"
  api_domain_name   = "keep-api.mgmt.example.com"
  api_image         = "111111111111.dkr.ecr.ap-northeast-1.amazonaws.com/keep/keep-api@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  ui_image          = "111111111111.dkr.ecr.ap-northeast-1.amazonaws.com/keep/keep-ui@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
}

run "embedded_scheduler_by_default" {
  command = plan

  assert {
    condition     = keys(aws_ecs_service.backend) == ["api"] && aws_ecs_service.backend["api"].desired_count == 2
    error_message = "Only the API service (2 tasks) by default."
  }

  assert {
    condition = contains(
      jsondecode(aws_ecs_task_definition.backend["api"].container_definitions)[0].environment,
      { name = "SCHEDULER", value = "true" }
    )
    error_message = "API tasks run the scheduler by default."
  }

  assert {
    condition = contains(
      jsondecode(aws_ecs_task_definition.backend["api"].container_definitions)[0].environment,
      { name = "KEEP_PULL_DATA_ENABLED", value = "false" }
    )
    error_message = "Pull must be disabled (push only)."
  }

  assert {
    condition     = aws_db_instance.main.multi_az && aws_db_instance.main.deletion_protection && aws_db_instance.main.password_wo_version == 1
    error_message = "Multi-AZ, deletion-protected RDS with a write-only password expected."
  }
}

run "dedicated_scheduler" {
  command = plan

  variables {
    enable_dedicated_scheduler = true
  }

  assert {
    condition     = aws_ecs_service.backend["scheduler"].desired_count == 1 && aws_ecs_service.backend["scheduler"].deployment_maximum_percent == 100
    error_message = "A single scheduler task that never overlaps during deployments expected."
  }

  assert {
    condition = contains(
      jsondecode(aws_ecs_task_definition.backend["api"].container_definitions)[0].environment,
      { name = "SCHEDULER", value = "false" }
    )
    error_message = "API tasks must stop scheduling when the dedicated scheduler is enabled."
  }
}

run "rejects_tag_pinned_images" {
  command = plan

  variables {
    api_image = "111111111111.dkr.ecr.ap-northeast-1.amazonaws.com/keep/keep-api:latest"
  }

  expect_failures = [var.api_image]
}
