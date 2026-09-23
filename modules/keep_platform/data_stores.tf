# --- RDS for PostgreSQL (Keep state) ----------------------------------------------------------

resource "aws_db_subnet_group" "main" {
  name       = var.name
  subnet_ids = var.subnet_ids
}

resource "aws_db_parameter_group" "main" {
  name   = "${var.name}-postgres${var.db_engine_version}"
  family = "postgres${var.db_engine_version}"

  parameter {
    name  = "rds.force_ssl"
    value = "1"
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_db_instance" "main" {
  identifier     = var.name
  engine         = "postgres"
  engine_version = var.db_engine_version
  instance_class = var.db_instance_class

  db_name  = "keep"
  username = "keep"
  # Write-only: generated ephemerally, never stored in state (see secrets.tf).
  password_wo         = ephemeral.random_password.db.result
  password_wo_version = var.secret_version

  allocated_storage     = var.db_allocated_storage_gb
  max_allocated_storage = var.db_max_allocated_storage_gb
  storage_type          = "gp3"
  storage_encrypted     = true

  multi_az               = true
  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.database.id]
  parameter_group_name   = aws_db_parameter_group.main.name
  publicly_accessible    = false

  backup_retention_period             = var.db_backup_retention_days
  copy_tags_to_snapshot               = true
  auto_minor_version_upgrade          = true
  performance_insights_enabled        = true
  monitoring_interval                 = 60
  monitoring_role_arn                 = aws_iam_role.rds_monitoring.arn
  iam_database_authentication_enabled = true
  enabled_cloudwatch_logs_exports     = ["postgresql", "upgrade"]

  deletion_protection       = true
  skip_final_snapshot       = false
  final_snapshot_identifier = "${var.name}-final"

  lifecycle {
    prevent_destroy = true
  }
}

# --- ElastiCache for Valkey (Keep ARQ / Redis queue) -------------------------------------------

resource "aws_elasticache_subnet_group" "main" {
  name       = var.name
  subnet_ids = var.subnet_ids
}

resource "aws_elasticache_replication_group" "main" {
  replication_group_id = var.name
  description          = "Keep ARQ queue"
  engine               = "valkey"
  engine_version       = var.cache_engine_version
  node_type            = var.cache_node_type
  port                 = 6379

  num_cache_clusters         = 2
  automatic_failover_enabled = true
  multi_az_enabled           = true

  subnet_group_name  = aws_elasticache_subnet_group.main.name
  security_group_ids = [aws_security_group.cache.id]

  at_rest_encryption_enabled = true
  # Keep's Redis client TLS support is unverified (implementation plan, open item); access is
  # restricted to the Keep task security group instead.
  transit_encryption_enabled = false

  snapshot_retention_limit = 1
}
