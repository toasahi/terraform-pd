# AlertEventJournal: durable, idempotent record of every alert transition (partition key =
# transition_id). Written with a conditional put; the SQS FIFO dedup window (5 minutes) is only a
# secondary guard.
#
# Settings that cannot be changed later without recreating the table are fixed here so that the
# phase-3 global table (Osaka replica) is a pure addition:
#   - Streams enabled with NEW_AND_OLD_IMAGES (required by global tables; StreamViewType is immutable)
#   - on-demand capacity
resource "aws_dynamodb_table" "main" {
  name         = var.table_name
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "transition_id"

  attribute {
    name = "transition_id"
    type = "S"
  }

  attribute {
    name = "state"
    type = "S"
  }

  attribute {
    name = "updated_at"
    type = "S"
  }

  # Finds transitions stuck before KEEP_ACCEPTED (replay and monitoring).
  global_secondary_index {
    name            = "state-updated_at"
    projection_type = "KEYS_ONLY"

    key_schema {
      attribute_name = "state"
      key_type       = "HASH"
    }

    key_schema {
      attribute_name = "updated_at"
      key_type       = "RANGE"
    }
  }

  stream_enabled   = true
  stream_view_type = "NEW_AND_OLD_IMAGES"

  ttl {
    attribute_name = "expires_at"
    enabled        = true
  }

  point_in_time_recovery {
    enabled = var.enable_point_in_time_recovery
  }

  server_side_encryption {
    enabled     = true
    kms_key_arn = var.kms_key_arn
  }

  deletion_protection_enabled = true

  lifecycle {
    prevent_destroy = true
  }
}
