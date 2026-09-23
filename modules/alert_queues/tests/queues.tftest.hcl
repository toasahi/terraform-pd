mock_provider "aws" {
  override_during = plan

  mock_resource "aws_sqs_queue" {
    defaults = {
      arn = "arn:aws:sqs:ap-northeast-1:111111111111:queue"
    }
  }
}

run "fifo_queues_with_dlq" {
  command = plan

  variables {
    name_prefix = "alert-pipeline"
    queues = {
      alerts        = { visibility_timeout_seconds = 180 }
      keep_delivery = { visibility_timeout_seconds = 360, max_receive_count = 8 }
    }
  }

  assert {
    condition     = aws_sqs_queue.main["keep_delivery"].name == "alert-pipeline-keep-delivery.fifo"
    error_message = "Queue names must be <prefix>-<key with hyphens>.fifo."
  }

  assert {
    condition     = aws_sqs_queue.dead_letter["alerts"].name == "alert-pipeline-alerts-dlq.fifo"
    error_message = "DLQ name mismatch."
  }

  assert {
    condition     = alltrue([for q in aws_sqs_queue.main : q.fifo_queue && !q.content_based_deduplication && q.sqs_managed_sse_enabled])
    error_message = "Queues must be FIFO, use explicit dedup ids and be encrypted."
  }

  assert {
    condition     = jsondecode(aws_sqs_queue.main["keep_delivery"].redrive_policy).maxReceiveCount == 8
    error_message = "max_receive_count must reach the redrive policy."
  }
}
