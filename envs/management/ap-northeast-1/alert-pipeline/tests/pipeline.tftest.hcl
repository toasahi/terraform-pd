# Plans the whole root offline: AWS is mocked and the upstream remote states are stubbed.
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
}

override_data {
  target = data.terraform_remote_state.foundation
  values = {
    outputs = {
      vpc_id             = "vpc-1"
      private_subnet_ids = ["subnet-1", "subnet-2", "subnet-3"]
    }
  }
}

override_data {
  target = data.terraform_remote_state.keep
  values = {
    outputs = {
      api_url                = "https://keep-api.mgmt.example.com"
      api_key_secret_arn     = "arn:aws:secretsmanager:ap-northeast-1:111111111111:secret:keep/api-key-dispatcher"
      cluster_name           = "keep"
      service_names          = { api = "keep-api", ui = "keep-ui" }
      service_desired_counts = { api = 2, ui = 1 }
    }
  }
}

override_resource {
  target          = module.ingress.aws_acm_certificate.main
  override_during = plan
  values = {
    arn = "arn:aws:acm:ap-northeast-1:111111111111:certificate/alerts"
    domain_validation_options = [{
      domain_name           = "alerts.mgmt.example.com"
      resource_record_name  = "_x.alerts.mgmt.example.com."
      resource_record_type  = "CNAME"
      resource_record_value = "_y.acm-validations.aws."
    }]
  }
}

variables {
  lambda_package_path = "./tests/fixtures/lambda.zip"
}

run "pipeline_wiring" {
  command = plan

  assert {
    condition     = aws_lambda_event_source_mapping.dispatcher.scaling_config[0].maximum_concurrency == 3
    error_message = "Dispatcher concurrency towards Keep must be capped at 3 by default."
  }

  assert {
    condition = alltrue([
      for esm in [aws_lambda_event_source_mapping.router, aws_lambda_event_source_mapping.dispatcher] :
      contains(esm.function_response_types, "ReportBatchItemFailures")
    ])
    error_message = "FIFO consumers must report partial batch failures."
  }

  assert {
    condition     = module.queues.queue_names["keep_delivery"] == "alert-pipeline-keep-delivery.fifo"
    error_message = "Unexpected keep-delivery queue name."
  }

  assert {
    condition     = module.ingress.endpoint_url == "https://alerts.mgmt.example.com/v1/alerts/"
    error_message = "The ingest endpoint must be served from the custom domain."
  }
}

run "inhouse_notifier_queue_created_by_default" {
  command = plan

  assert {
    condition     = module.queues.queue_names["critical_inhouse"] == "alert-pipeline-critical-inhouse.fifo"
    error_message = "A FIFO queue for the in-house notifier must be created by default."
  }

  assert {
    condition     = contains(keys(module.queues.dead_letter_queue_names), "critical_inhouse")
    error_message = "The in-house notifier queue needs a DLQ (tool-side failures)."
  }
}

run "existing_inhouse_notifier_queue" {
  command = plan

  variables {
    inhouse_notifier_existing_queue_arn = "arn:aws:sqs:ap-northeast-1:111111111111:inhouse-notifier.fifo"
  }

  assert {
    condition     = !contains(keys(module.queues.queue_names), "critical_inhouse")
    error_message = "No queue must be created when the tool's existing queue is used."
  }

  assert {
    condition     = output.inhouse_notifier_queue_url == "https://sqs.ap-northeast-1.amazonaws.com/111111111111/inhouse-notifier.fifo"
    error_message = "The queue URL must be derived from the existing queue ARN."
  }
}

run "rejects_invalid_inhouse_queue_arn" {
  command = plan

  variables {
    inhouse_notifier_existing_queue_arn = "arn:aws:sns:ap-northeast-1:111111111111:topic"
  }

  expect_failures = [var.inhouse_notifier_existing_queue_arn]
}

run "rejects_reserved_concurrency_below_maximum" {
  command = plan

  variables {
    dispatcher_maximum_concurrency  = 5
    dispatcher_reserved_concurrency = 3
  }

  expect_failures = [var.dispatcher_reserved_concurrency]
}

run "rejects_uncapped_dispatcher" {
  command = plan

  variables {
    dispatcher_maximum_concurrency  = 20
    dispatcher_reserved_concurrency = 20
  }

  expect_failures = [var.dispatcher_maximum_concurrency]
}
