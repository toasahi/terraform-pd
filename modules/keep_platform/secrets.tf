# Secrets are generated with ephemeral random_password and written through write-only arguments
# (secret_string_wo / password_wo): the values never enter the Terraform plan or state. Bump
# var.secret_version to rotate them (the DB password and the connection string rotate together).

locals {
  generated_secrets = {
    "database-connection-string" = "Keep DATABASE_CONNECTION_STRING (SQLAlchemy URL incl. password)"
    "jwt-secret"                 = "Keep KEEP_JWT_SECRET"
    "nextauth-secret"            = "Keep UI NEXTAUTH_SECRET"
    "admin-password"             = "Keep KEEP_DEFAULT_PASSWORD (initial admin, AUTH_TYPE=DB)"
  }
}

resource "aws_secretsmanager_secret" "generated" {
  for_each = local.generated_secrets

  name        = "${var.name}/${each.key}"
  description = each.value
}

# Created in Keep (Settings > API Keys) after the first deployment and stored here by an operator
# (`aws secretsmanager put-secret-value`); read by the Dispatcher Lambda.
resource "aws_secretsmanager_secret" "api_key" {
  name        = "${var.name}/api-key-dispatcher"
  description = "Keep API key used by the alert Dispatcher Lambda (X-API-KEY). Value set manually."
}

ephemeral "random_password" "db" {
  length  = 40
  special = false
}

ephemeral "random_password" "jwt" {
  length  = 64
  special = false
}

ephemeral "random_password" "nextauth" {
  length  = 64
  special = false
}

ephemeral "random_password" "admin" {
  length  = 32
  special = false
}

resource "aws_secretsmanager_secret_version" "database_connection_string" {
  secret_id                = aws_secretsmanager_secret.generated["database-connection-string"].id
  secret_string_wo         = "postgresql+psycopg2://${aws_db_instance.main.username}:${ephemeral.random_password.db.result}@${aws_db_instance.main.address}:${aws_db_instance.main.port}/${aws_db_instance.main.db_name}?sslmode=require"
  secret_string_wo_version = var.secret_version
}

resource "aws_secretsmanager_secret_version" "jwt_secret" {
  secret_id                = aws_secretsmanager_secret.generated["jwt-secret"].id
  secret_string_wo         = ephemeral.random_password.jwt.result
  secret_string_wo_version = var.secret_version
}

resource "aws_secretsmanager_secret_version" "nextauth_secret" {
  secret_id                = aws_secretsmanager_secret.generated["nextauth-secret"].id
  secret_string_wo         = ephemeral.random_password.nextauth.result
  secret_string_wo_version = var.secret_version
}

resource "aws_secretsmanager_secret_version" "admin_password" {
  secret_id                = aws_secretsmanager_secret.generated["admin-password"].id
  secret_string_wo         = ephemeral.random_password.admin.result
  secret_string_wo_version = var.secret_version
}
