locals {
  queue_names = { for key, _ in var.queues : key => "${var.name_prefix}-${replace(key, "_", "-")}" }
}

resource "aws_sqs_queue" "dead_letter" {
  for_each = var.queues

  name                        = "${local.queue_names[each.key]}-dlq.fifo"
  fifo_queue                  = true
  content_based_deduplication = false
  message_retention_seconds   = 1209600

  sqs_managed_sse_enabled = var.kms_master_key_id == null ? true : null
  kms_master_key_id       = var.kms_master_key_id
}

# MessageGroupId = fingerprint (ordering per alert), MessageDeduplicationId = transition_id.
# High-throughput FIFO mode: deduplication and throughput limits apply per message group.
resource "aws_sqs_queue" "main" {
  for_each = var.queues

  name                        = "${local.queue_names[each.key]}.fifo"
  fifo_queue                  = true
  content_based_deduplication = false
  deduplication_scope         = "messageGroup"
  fifo_throughput_limit       = "perMessageGroupId"
  visibility_timeout_seconds  = each.value.visibility_timeout_seconds
  message_retention_seconds   = each.value.message_retention_seconds

  sqs_managed_sse_enabled = var.kms_master_key_id == null ? true : null
  kms_master_key_id       = var.kms_master_key_id

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.dead_letter[each.key].arn
    maxReceiveCount     = each.value.max_receive_count
  })
}

resource "aws_sqs_queue_redrive_allow_policy" "dead_letter" {
  for_each = var.queues

  queue_url = aws_sqs_queue.dead_letter[each.key].id
  redrive_allow_policy = jsonencode({
    redrivePermission = "byQueue"
    sourceQueueArns   = [aws_sqs_queue.main[each.key].arn]
  })
}
