locals {
  http_port = 80
  # The port the image listens on (APP_PORT in app/Dockerfile).
  container_port = 3000
  # Must match ECS_STOP_TIMEOUT_MS in app/src/config.ts, which bounds the app's shutdown deadline.
  stop_timeout_seconds = 30

  deregistration_delay_seconds  = 30
  health_check_interval_seconds = 10
  health_check_timeout_seconds  = 5
  healthy_threshold             = 2
  unhealthy_threshold           = 3
  # Long enough for a new task to boot and pass its first health checks before the ALB's count.
  health_check_grace_seconds = 30

  container_health_interval_seconds = 15
  container_health_timeout_seconds  = 5
  container_health_retries          = 3
  container_health_start_seconds    = 10

  # One-off and short-lived; not part of vertical scaling.
  migrate_cpu        = 256
  migrate_memory_mib = 512

  image = "${var.repository_url}:${var.image_tag}"

  # Secrets each task's execution role may read.
  task_secret_arns = {
    api     = [var.database.app_secret_arn]
    migrate = [var.database.app_secret_arn, var.database.master_secret_arn]
  }

  database_environment = [
    { name = "DB_HOST", value = var.database.address },
    { name = "DB_PORT", value = tostring(var.database.port) },
    { name = "DB_NAME", value = var.database.name },
  ]

  container_defaults = {
    image                  = local.image
    essential              = true
    readonlyRootFilesystem = true
    stopTimeout            = local.stop_timeout_seconds
  }
}

resource "aws_cloudwatch_log_group" "tasks" {
  name              = "/taskflow/ecs/${var.name}"
  retention_in_days = var.log_retention_days
}

# Secrets Manager JSON keys, injected by the ECS agent at start; never in the task definition.
locals {
  app_credentials = [
    { name = "DB_USER", valueFrom = "${var.database.app_secret_arn}:username::" },
    { name = "DB_PASSWORD", valueFrom = "${var.database.app_secret_arn}:password::" },
  ]

  migrate_credentials = [
    { name = "DB_USER", valueFrom = "${var.database.master_secret_arn}:username::" },
    { name = "DB_PASSWORD", valueFrom = "${var.database.master_secret_arn}:password::" },
    { name = "APP_DB_USER", valueFrom = "${var.database.app_secret_arn}:username::" },
    { name = "APP_DB_PASSWORD", valueFrom = "${var.database.app_secret_arn}:password::" },
  ]
}

resource "aws_ecs_task_definition" "api" {
  family                   = "${var.name}-api"
  requires_compatibilities = ["EC2"]
  network_mode             = "awsvpc"
  cpu                      = local.api_task_size.cpu
  memory                   = local.api_task_size.memory
  execution_role_arn       = aws_iam_role.execution["api"].arn
  task_role_arn            = aws_iam_role.task.arn
  # Keeps earlier revisions registered, so a rollback can return to one.
  skip_destroy = true

  container_definitions = jsonencode([merge(local.container_defaults, {
    name = "api"
    environment = concat(local.database_environment, [
      { name = "LOG_LEVEL", value = var.log_level },
    ])
    secrets      = local.app_credentials
    portMappings = [{ containerPort = local.container_port, protocol = "tcp" }]
    healthCheck = {
      command     = ["CMD", "/nodejs/bin/node", "dist/healthcheck.js"]
      interval    = local.container_health_interval_seconds
      timeout     = local.container_health_timeout_seconds
      retries     = local.container_health_retries
      startPeriod = local.container_health_start_seconds
    }
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        awslogs-group         = aws_cloudwatch_log_group.tasks.name
        awslogs-region        = data.aws_region.current.region
        awslogs-stream-prefix = "api"
      }
    }
  })])

  depends_on = [aws_iam_role_policy.execution]
}

resource "aws_ecs_task_definition" "migrate" {
  family                   = "${var.name}-migrate"
  requires_compatibilities = ["EC2"]
  network_mode             = "awsvpc"
  cpu                      = local.migrate_cpu
  memory                   = local.migrate_memory_mib
  execution_role_arn       = aws_iam_role.execution["migrate"].arn
  task_role_arn            = aws_iam_role.task.arn
  skip_destroy             = true

  container_definitions = jsonencode([merge(local.container_defaults, {
    name        = "migrate"
    command     = ["dist/migrate.js"]
    environment = local.database_environment
    secrets     = local.migrate_credentials
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        awslogs-group         = aws_cloudwatch_log_group.tasks.name
        awslogs-region        = data.aws_region.current.region
        awslogs-stream-prefix = "migrate"
      }
    }
  })])

  depends_on = [aws_iam_role_policy.execution]
}

resource "aws_ecs_service" "api" {
  name            = "${var.name}-api"
  cluster         = var.cluster_arn
  task_definition = aws_ecs_task_definition.api.arn
  desired_count   = var.desired_count

  capacity_provider_strategy {
    capacity_provider = var.capacity_provider_name
    weight            = 1
  }

  network_configuration {
    subnets          = var.private_subnet_ids
    security_groups  = [aws_security_group.tasks.id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.api.arn
    container_name   = "api"
    container_port   = local.container_port
  }

  health_check_grace_period_seconds = local.health_check_grace_seconds

  # Start new tasks before stopping old ones, so a deployment never drops below desired capacity.
  deployment_minimum_healthy_percent = 100
  deployment_maximum_percent         = 200

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  ordered_placement_strategy {
    type  = "spread"
    field = "attribute:ecs.availability-zone"
  }

  # Spread only applies at placement; tasks placed while one AZ's host was being replaced would
  # otherwise stay in one AZ.
  availability_zone_rebalancing = "ENABLED"

  propagate_tags = "SERVICE"

  # scripts/deploy.sh moves the service to a new revision once its migration has succeeded, and
  # autoscaling owns the task count; Terraform only registers the revisions.
  lifecycle {
    ignore_changes = [task_definition, desired_count]
  }

  # The target group must be attached to the ALB before a service can register into it.
  depends_on = [aws_lb_listener.http]
}
