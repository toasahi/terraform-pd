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

  # Keep workflows (amazonsqs provider) may only send to these queues.
  sqs_send_queue_arns = local.sqs_send_queue_arns
}

# --- Non-critical alerts: Keep workflow -> SQS FIFO -> in-house notifier Lambda -----------------
# Keep decides whether to notify (deduplication, suppression); the in-house notifier routes each
# message to a room by labels.system (see docs/non-critical-notification-contract.md).
# The queue lives in this root, next to its only sender, so that no state is read "backwards"
# (foundation -> keep -> alert-pipeline). alert-pipeline reads the names below for its alarms.
#
# Invariant: Keep's task role gets SendMessage only, never ReceiveMessage/DeleteMessage. Keep runs
# with CONSUMER=true and the amazonsqs provider can consume; with receive rights Keep would take the
# notifier's messages, ingest them as alerts and send them again through the workflow (a loop).
module "notification_queues" {
  source = "../../../../modules/alert_queues"

  name_prefix = "keep"
  queues = {
    # visibility timeout = 6 x the in-house notifier Lambda timeout (consumer lives in the tool repo)
    non_critical_inhouse = { visibility_timeout_seconds = var.inhouse_notifier_visibility_timeout_seconds }
  }
}

locals {
  sqs_send_queue_arns = [module.notification_queues.queue_arns["non_critical_inhouse"]]

  # The workflow is deployed to Keep by an operator; it is read here only to guard its invariants.
  non_critical_workflow = yamldecode(file("${path.module}/../../../../keep-workflows/non-critical-to-inhouse.yaml"))
  non_critical_sqs_actions = [
    for action in local.non_critical_workflow.workflow.actions : action
    if action.provider.type == "amazonsqs"
  ]
}

# Keep's amazonsqs provider sends MessageGroupId / MessageDeduplicationId to a .fifo queue and
# requires both arguments (keep/providers/amazonsqs_provider/amazonsqs_provider.py, _notify).
check "non_critical_workflow_fits_fifo_queue" {
  assert {
    condition = length(local.non_critical_sqs_actions) > 0 && alltrue([
      for action in local.non_critical_sqs_actions :
      contains(keys(action.provider.with), "group_id") && contains(keys(action.provider.with), "dedup_id")
    ])
    error_message = "keep-workflows/non-critical-to-inhouse.yaml: every amazonsqs action must set with.group_id and with.dedup_id (the queue is FIFO)."
  }
}
