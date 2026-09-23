module "monitoring" {
  source = "../../../../modules/alert_monitoring"

  name                  = local.name
  alarm_email_endpoints = var.alarm_email_endpoints

  queues = {
    alerts        = { queue_name = module.queues.queue_names["alerts"], max_oldest_message_seconds = 300 }
    keep_delivery = { queue_name = module.queues.queue_names["keep_delivery"], max_oldest_message_seconds = 900 }
  }
  dead_letter_queue_names = module.queues.dead_letter_queue_names

  lambda_function_names = {
    authorizer = module.authorizer.function_name
    ingest     = module.ingest.function_name
    router     = module.router.function_name
    dispatcher = module.dispatcher.function_name
  }
  throttle_watched_functions = ["dispatcher"]

  api = {
    api_name   = module.ingress.rest_api_name
    stage_name = module.ingress.stage_name
  }
  web_acl_name = module.ingress.web_acl_name

  ecs_services = {
    for role, service_name in local.keep.service_names : "keep-${role}" => {
      cluster_name      = local.keep.cluster_name
      service_name      = service_name
      min_running_tasks = local.keep.service_desired_counts[role]
    }
  }
}
