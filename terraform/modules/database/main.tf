locals {
  slow_statement_threshold_ms = 1000
  # Longer Performance Insights retention is billed; 7 days is the free tier.
  free_insights_retention_days = 7
}

# Inbound rules are added by the service module, which owns the task security group; until then
# nothing can reach the database. RDS never initiates connections, so there is no egress.
resource "aws_security_group" "db" {
  name        = "${var.name}-db"
  description = "PostgreSQL; ingress only from the TaskFlow task security group"
  vpc_id      = var.vpc_id

  tags = { Name = "${var.name}-db" }
}

resource "aws_db_subnet_group" "this" {
  name       = var.name
  subnet_ids = var.subnet_ids

  tags = { Name = var.name }
}

resource "aws_db_parameter_group" "this" {
  name_prefix = "${var.name}-pg${var.engine_version}-"
  family      = "postgres${var.engine_version}"

  # Already the default on PostgreSQL 15+; explicit so it cannot be lost to a default change.
  parameter {
    name  = "rds.force_ssl"
    value = "1"
  }

  # Statements slower than this are logged, which is the first clue in a pool-exhaustion incident.
  parameter {
    name  = "log_min_duration_statement"
    value = tostring(local.slow_statement_threshold_ms)
  }

  lifecycle {
    create_before_destroy = true
  }
}

# Created before the instance so RDS does not create it first with "never expire" retention.
resource "aws_cloudwatch_log_group" "postgresql" {
  name              = "/aws/rds/instance/${var.name}/postgresql"
  retention_in_days = var.log_retention_days
}

# Final snapshot names must be unique; a new suffix for each instance keeps repeated teardowns of a
# protected database from failing on "snapshot already exists". The keepers are the inputs that force
# the instance to be replaced, so the suffix changes with it. A manual `-replace` of the instance
# must also replace this resource.
resource "random_id" "final_snapshot" {
  byte_length = 4

  keepers = {
    identifier      = var.name
    database_name   = var.database_name
    master_username = var.master_username
  }
}

resource "aws_db_instance" "this" {
  identifier     = var.name
  engine         = "postgres"
  engine_version = var.engine_version
  instance_class = var.instance_class

  storage_type          = "gp3"
  allocated_storage     = var.allocated_storage_gb
  max_allocated_storage = var.max_allocated_storage_gb
  storage_encrypted     = true

  db_name  = var.database_name
  username = var.master_username
  # RDS generates the master password and keeps it in Secrets Manager; it never enters Terraform state.
  manage_master_user_password = true

  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = [aws_security_group.db.id]
  parameter_group_name   = aws_db_parameter_group.this.name
  publicly_accessible    = false
  # ponytail: single-AZ; an AZ outage takes the database down. Upgrade: multi_az = true (README non-goals).
  multi_az = false

  backup_retention_period = var.backup_retention_days
  backup_window           = "19:00-19:30" # UTC; 00:30-01:00 in Sri Lanka
  maintenance_window      = "sun:20:00-sun:20:30"
  copy_tags_to_snapshot   = true

  deletion_protection       = var.deletion_protection
  skip_final_snapshot       = !var.final_snapshot
  final_snapshot_identifier = "${var.name}-final-${random_id.final_snapshot.hex}"

  auto_minor_version_upgrade            = true
  performance_insights_enabled          = true
  performance_insights_retention_period = local.free_insights_retention_days
  enabled_cloudwatch_logs_exports       = ["postgresql"]

  depends_on = [aws_cloudwatch_log_group.postgresql]
}

# The API's credentials. Terraform generates the password, so it is in the (encrypted, private)
# state; the master password, which can do far more, is not.
resource "random_password" "app" {
  length  = 32
  special = false
}

resource "aws_secretsmanager_secret" "app" {
  # A prefix gives each instance of the secret a unique name, so re-creating the stack after a
  # teardown is not blocked by the previous secret's deletion recovery window.
  name_prefix = "${var.name}/db/app-"
  description = "TaskFlow API database credentials (restricted role)"
}

resource "aws_secretsmanager_secret_version" "app" {
  secret_id = aws_secretsmanager_secret.app.id
  secret_string = jsonencode({
    username = var.app_username
    password = random_password.app.result
  })
}
