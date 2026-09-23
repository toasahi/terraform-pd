locals {
  # Keep backend services. With the dedicated scheduler enabled, the API tasks stop running the
  # interval workflow scheduler and a single-task service owns it instead.
  backend_services = merge(
    {
      api = {
        desired_count = var.api_desired_count
        scheduler     = var.enable_dedicated_scheduler ? "false" : "true"
        load_balanced = true
        # Rolling update with extra capacity.
        deployment_minimum_healthy_percent = 100
        deployment_maximum_percent         = 200
      }
    },
    var.enable_dedicated_scheduler ? {
      scheduler = {
        desired_count = 1
        scheduler     = "true"
        load_balanced = false
        # Never run two schedulers at once, even during a deployment.
        deployment_minimum_healthy_percent = 0
        deployment_maximum_percent         = 100
      }
    } : {},
  )

  runtime_platform = {
    operating_system_family = "LINUX"
    cpu_architecture        = var.cpu_architecture
  }
}

resource "aws_cloudwatch_log_group" "container" {
  for_each = toset(concat(keys(local.backend_services), ["ui"]))

  name              = "/ecs/${var.name}/${each.key}"
  retention_in_days = var.log_retention_days
}

# --- Keep backend (API / scheduler) ----------------------------------------------------------

resource "aws_ecs_task_definition" "backend" {
  for_each = local.backend_services

  family                   = "${var.name}-${each.key}"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.api_cpu_units
  memory                   = var.api_memory_mb
  execution_role_arn       = aws_iam_role.execution.arn
  task_role_arn            = aws_iam_role.task.arn

  runtime_platform {
    operating_system_family = local.runtime_platform.operating_system_family
    cpu_architecture        = local.runtime_platform.cpu_architecture
  }

  container_definitions = jsonencode([{
    name      = "keep-backend"
    image     = var.api_image
    essential = true
    portMappings = [{
      containerPort = local.api_port
      protocol      = "tcp"
    }]
    environment = [
      for key, value in merge(local.backend_environment, { SCHEDULER = each.value.scheduler, KEEP_DEFAULT_USERNAME = "keep-admin" }) : { name = key, value = value }
    ]
    secrets = [
      for key, arn in local.backend_secrets : { name = key, valueFrom = arn }
    ]
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        awslogs-group         = aws_cloudwatch_log_group.container[each.key].name
        awslogs-region        = local.region
        awslogs-stream-prefix = each.key
      }
    }
  }])
}

resource "aws_ecs_service" "backend" {
  for_each = local.backend_services

  name                   = "${var.name}-${each.key}"
  cluster                = aws_ecs_cluster.main.id
  task_definition        = aws_ecs_task_definition.backend[each.key].arn
  desired_count          = each.value.desired_count
  launch_type            = "FARGATE"
  enable_execute_command = var.enable_execute_command
  propagate_tags         = "SERVICE"

  deployment_minimum_healthy_percent = each.value.deployment_minimum_healthy_percent
  deployment_maximum_percent         = each.value.deployment_maximum_percent
  health_check_grace_period_seconds  = each.value.load_balanced ? 180 : null

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  network_configuration {
    subnets          = var.subnet_ids
    security_groups  = [aws_security_group.task.id]
    assign_public_ip = false
  }

  dynamic "load_balancer" {
    for_each = each.value.load_balanced ? [1] : []

    content {
      target_group_arn = aws_lb_target_group.api.arn
      container_name   = "keep-backend"
      container_port   = local.api_port
    }
  }

  depends_on = [aws_lb_listener_rule.api]
}

# --- Keep UI ---------------------------------------------------------------------------------

resource "aws_ecs_task_definition" "ui" {
  family                   = "${var.name}-ui"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.ui_cpu_units
  memory                   = var.ui_memory_mb
  execution_role_arn       = aws_iam_role.execution.arn

  runtime_platform {
    operating_system_family = local.runtime_platform.operating_system_family
    cpu_architecture        = local.runtime_platform.cpu_architecture
  }

  container_definitions = jsonencode([{
    name      = "keep-frontend"
    image     = var.ui_image
    essential = true
    portMappings = [{
      containerPort = local.ui_port
      protocol      = "tcp"
    }]
    environment = [for key, value in local.ui_environment : { name = key, value = value }]
    secrets     = [for key, arn in local.ui_secrets : { name = key, valueFrom = arn }]
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        awslogs-group         = aws_cloudwatch_log_group.container["ui"].name
        awslogs-region        = local.region
        awslogs-stream-prefix = "ui"
      }
    }
  }])
}

resource "aws_ecs_service" "ui" {
  name                   = "${var.name}-ui"
  cluster                = aws_ecs_cluster.main.id
  task_definition        = aws_ecs_task_definition.ui.arn
  desired_count          = var.ui_desired_count
  launch_type            = "FARGATE"
  enable_execute_command = var.enable_execute_command
  propagate_tags         = "SERVICE"

  health_check_grace_period_seconds = 120

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  network_configuration {
    subnets          = var.subnet_ids
    security_groups  = [aws_security_group.task.id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.ui.arn
    container_name   = "keep-frontend"
    container_port   = local.ui_port
  }

  depends_on = [aws_lb_listener_rule.ui]
}
