mock_provider "aws" {}

run "global_table_ready" {
  command = plan

  variables {
    table_name = "AlertEventJournal"
  }

  assert {
    condition     = aws_dynamodb_table.main.stream_enabled && aws_dynamodb_table.main.stream_view_type == "NEW_AND_OLD_IMAGES"
    error_message = "Streams must be NEW_AND_OLD_IMAGES (global table requirement, immutable)."
  }

  assert {
    condition     = aws_dynamodb_table.main.billing_mode == "PAY_PER_REQUEST" && aws_dynamodb_table.main.deletion_protection_enabled
    error_message = "On-demand capacity and deletion protection expected."
  }
}
