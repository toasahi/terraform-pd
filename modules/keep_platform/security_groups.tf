resource "aws_security_group" "alb" {
  name        = "${var.name}-alb"
  description = "Keep internal ALB"
  vpc_id      = var.vpc_id
}

resource "aws_vpc_security_group_ingress_rule" "alb_https" {
  for_each = toset(var.alb_ingress_cidrs)

  security_group_id = aws_security_group.alb.id
  description       = "HTTPS from ${each.value}"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = each.value
}

resource "aws_vpc_security_group_egress_rule" "alb_to_api" {
  security_group_id            = aws_security_group.alb.id
  description                  = "Keep API tasks"
  ip_protocol                  = "tcp"
  from_port                    = local.api_port
  to_port                      = local.api_port
  referenced_security_group_id = aws_security_group.task.id
}

resource "aws_vpc_security_group_egress_rule" "alb_to_ui" {
  security_group_id            = aws_security_group.alb.id
  description                  = "Keep UI tasks"
  ip_protocol                  = "tcp"
  from_port                    = local.ui_port
  to_port                      = local.ui_port
  referenced_security_group_id = aws_security_group.task.id
}

resource "aws_security_group" "task" {
  name        = "${var.name}-task"
  description = "Keep ECS tasks"
  vpc_id      = var.vpc_id
}

resource "aws_vpc_security_group_ingress_rule" "task_api" {
  security_group_id            = aws_security_group.task.id
  description                  = "Keep API from ALB"
  ip_protocol                  = "tcp"
  from_port                    = local.api_port
  to_port                      = local.api_port
  referenced_security_group_id = aws_security_group.alb.id
}

resource "aws_vpc_security_group_ingress_rule" "task_ui" {
  security_group_id            = aws_security_group.task.id
  description                  = "Keep UI from ALB"
  ip_protocol                  = "tcp"
  from_port                    = local.ui_port
  to_port                      = local.ui_port
  referenced_security_group_id = aws_security_group.alb.id
}

# Image pulls, AWS APIs and outbound notifications from Keep workflows.
resource "aws_vpc_security_group_egress_rule" "task_https" {
  security_group_id = aws_security_group.task.id
  description       = "HTTPS egress"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_egress_rule" "task_database" {
  security_group_id            = aws_security_group.task.id
  description                  = "PostgreSQL"
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
  referenced_security_group_id = aws_security_group.database.id
}

resource "aws_vpc_security_group_egress_rule" "task_cache" {
  security_group_id            = aws_security_group.task.id
  description                  = "Valkey"
  ip_protocol                  = "tcp"
  from_port                    = 6379
  to_port                      = 6379
  referenced_security_group_id = aws_security_group.cache.id
}

resource "aws_security_group" "database" {
  name        = "${var.name}-database"
  description = "Keep RDS for PostgreSQL"
  vpc_id      = var.vpc_id
}

resource "aws_vpc_security_group_ingress_rule" "database_from_task" {
  security_group_id            = aws_security_group.database.id
  description                  = "PostgreSQL from Keep tasks"
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
  referenced_security_group_id = aws_security_group.task.id
}

resource "aws_security_group" "cache" {
  name        = "${var.name}-cache"
  description = "Keep ElastiCache for Valkey"
  vpc_id      = var.vpc_id
}

resource "aws_vpc_security_group_ingress_rule" "cache_from_task" {
  security_group_id            = aws_security_group.cache.id
  description                  = "Valkey from Keep tasks"
  ip_protocol                  = "tcp"
  from_port                    = 6379
  to_port                      = 6379
  referenced_security_group_id = aws_security_group.task.id
}
