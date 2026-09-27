# Plans the whole root offline: AWS is mocked and the foundation remote state is stubbed.
mock_provider "aws" {
  override_during = plan

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

  mock_resource "aws_sqs_queue" {
    defaults = {
      arn = "arn:aws:sqs:ap-northeast-1:111111111111:queue"
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

# The real (offline) random provider: mock providers cannot serve ephemeral resources.

override_data {
  target = data.terraform_remote_state.foundation
  values = {
    outputs = {
      vpc_id             = "vpc-1"
      private_subnet_ids = ["subnet-1", "subnet-2", "subnet-3"]
      vpc_cidr_block     = "10.40.0.0/20"
      repository_urls = {
        "keep/keep-api" = "111111111111.dkr.ecr.ap-northeast-1.amazonaws.com/keep/keep-api"
        "keep/keep-ui"  = "111111111111.dkr.ecr.ap-northeast-1.amazonaws.com/keep/keep-ui"
      }
    }
  }
}

override_resource {
  target          = module.keep_platform.aws_acm_certificate.main
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
  target          = module.keep_platform.aws_elasticache_replication_group.main
  override_during = plan
  values = {
    primary_endpoint_address = "keep.cache.apne1.cache.amazonaws.com"
  }
}

override_resource {
  target          = module.keep_platform.aws_secretsmanager_secret.generated
  override_during = plan
  values = {
    arn = "arn:aws:secretsmanager:ap-northeast-1:111111111111:secret:keep/generated"
  }
}

# A distinct ARN/URL for the main non-critical queue, so assertions can tell it apart from its DLQ
# (every other queue gets the mock default ARN).
override_resource {
  target          = module.notification_queues.aws_sqs_queue.main["non_critical_inhouse"]
  override_during = plan
  values = {
    arn = "arn:aws:sqs:ap-northeast-1:111111111111:keep-non-critical-inhouse.fifo"
    url = "https://sqs.ap-northeast-1.amazonaws.com/111111111111/keep-non-critical-inhouse.fifo"
  }
}

run "non_critical_inhouse_queue" {
  command = plan

  assert {
    condition     = module.notification_queues.queue_names["non_critical_inhouse"] == "keep-non-critical-inhouse.fifo"
    error_message = "The non-critical queue for the in-house notifier must be keep-non-critical-inhouse.fifo."
  }

  assert {
    condition     = contains(keys(module.notification_queues.dead_letter_queue_names), "non_critical_inhouse")
    error_message = "The non-critical queue needs a DLQ (tool-side failures)."
  }

  assert {
    condition     = !contains(keys(module.notification_queues.queue_names), "critical_inhouse")
    error_message = "Critical notifications keep their own queue in alert-pipeline; the keep root must not create it."
  }
}

run "keep_can_send_to_non_critical_queue" {
  command = plan

  assert {
    condition     = local.sqs_send_queue_arns == ["arn:aws:sqs:ap-northeast-1:111111111111:keep-non-critical-inhouse.fifo"]
    error_message = "Keep's task role must be allowed to send to the non-critical queue (and nothing else, not its DLQ)."
  }

  assert {
    condition     = output.non_critical_inhouse_queue_arn == "arn:aws:sqs:ap-northeast-1:111111111111:keep-non-critical-inhouse.fifo"
    error_message = "The main queue ARN (not the DLQ's) must be exported for the in-house notifier's event source mapping."
  }

  assert {
    condition     = output.non_critical_inhouse_queue_url == "https://sqs.ap-northeast-1.amazonaws.com/111111111111/keep-non-critical-inhouse.fifo"
    error_message = "The main queue URL must be exported for Keep's amazonsqs provider (sqs_queue_url)."
  }

  assert {
    condition     = output.non_critical_inhouse_queue_name == "keep-non-critical-inhouse.fifo"
    error_message = "alert-pipeline's oldest-message-age alarm watches this name; it must be the main queue."
  }

  assert {
    condition     = output.non_critical_inhouse_dead_letter_queue_name == "keep-non-critical-inhouse-dlq.fifo"
    error_message = "alert-pipeline's DLQ-not-empty alarm watches this name; it must be the DLQ."
  }
}

run "non_critical_workflow_shape" {
  command = plan

  assert {
    condition     = local.non_critical_workflow.workflow.triggers[0].type == "alert" && local.non_critical_workflow.workflow.triggers[0].cel == "severity != \"critical\""
    error_message = "The workflow must trigger on every alert whose Keep severity is not critical."
  }

  assert {
    condition     = length(local.non_critical_workflow.workflow.actions) == 1 && local.non_critical_workflow.workflow.actions[0].provider.type == "amazonsqs"
    error_message = "The workflow must have exactly one amazonsqs action."
  }

  assert {
    condition     = toset(keys(local.non_critical_workflow.workflow.actions[0].provider.with)) == toset(["message", "group_id", "dedup_id"])
    error_message = "The amazonsqs action must pass message, group_id and dedup_id (FIFO queue)."
  }

  assert {
    condition     = alltrue([for v in values(local.non_critical_workflow.workflow.actions[0].provider.with) : !strcontains(v, "labels.system")])
    error_message = "The action must not reference labels.system: a missing label fails the render and breaks the fallback room."
  }
}
