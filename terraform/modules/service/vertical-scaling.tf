# Vertical scaling: when the service is already at its maximum task count and still runs hot, a
# composite alarm invokes a Lambda that moves the API task one step up a fixed size ladder and
# rolls the service out to it (vertical_scaler/handler.py).

locals {
  # Every size fits two per t3.small host (2048 CPU units and 1913 MiB registered; the ENI limit
  # allows two awsvpc tasks per host), so a deployment can always start new tasks beside old ones
  # on the ASG's four hosts. 1024 units is one vCPU, all that a single Node.js process can use.
  api_task_sizes = [
    { cpu = 256, memory = 512 },
    { cpu = 512, memory = 768 },
    { cpu = 1024, memory = 896 },
  ]

  # The task definition reads the size the Lambda last chose, so a release keeps it.
  api_task_size = jsondecode(aws_ssm_parameter.api_task_size.insecure_value)

  vertical_threshold_percent = 80
  metric_period_seconds      = 60
  # "Sustained": every one-minute datapoint for five minutes.
  sustained_periods = 5

  vertical_scaler_name            = "${var.name}-vertical-scaler"
  vertical_scaler_timeout_seconds = 30
}

# Terraform creates it at the smallest size; after that only the Lambda (or an operator) changes it.
resource "aws_ssm_parameter" "api_task_size" {
  name           = "/${var.name}/api/task-size"
  description    = "CPU and memory of the API task, set by the vertical scaler"
  type           = "String"
  insecure_value = jsonencode(local.api_task_sizes[0])

  lifecycle {
    ignore_changes = [insecure_value]
  }
}

resource "aws_cloudwatch_metric_alarm" "api_utilization_high" {
  for_each = {
    cpu    = "CPUUtilization"
    memory = "MemoryUtilization"
  }

  alarm_name          = "${var.name}-api-${each.key}-high"
  alarm_description   = "API ${each.key} above ${local.vertical_threshold_percent}% for ${local.sustained_periods} minutes"
  namespace           = "AWS/ECS"
  metric_name         = each.value
  dimensions          = { ClusterName = var.cluster_name, ServiceName = aws_ecs_service.api.name }
  statistic           = "Average"
  period              = local.metric_period_seconds
  evaluation_periods  = local.sustained_periods
  threshold           = local.vertical_threshold_percent
  comparison_operator = "GreaterThanThreshold"
}

# Sustained too: without it, reaching the maximum while utilization is already high would resize the
# tasks before the added tasks had a chance to help.
resource "aws_cloudwatch_metric_alarm" "api_at_max_tasks" {
  alarm_name          = "${var.name}-api-at-max-tasks"
  alarm_description   = "API desired count at the Service Auto Scaling maximum for ${local.sustained_periods} minutes"
  namespace           = "ECS/ContainerInsights"
  metric_name         = "DesiredTaskCount"
  dimensions          = { ClusterName = var.cluster_name, ServiceName = aws_ecs_service.api.name }
  statistic           = "Minimum"
  period              = local.metric_period_seconds
  evaluation_periods  = local.sustained_periods
  threshold           = local.max_task_count
  comparison_operator = "GreaterThanOrEqualToThreshold"
}

# Actions run only on the transition into ALARM, so each episode of sustained load is one step. The
# Lambda re-arms it when a deployment in progress makes it wait.
resource "aws_cloudwatch_composite_alarm" "api_vertical_scale" {
  alarm_name        = "${var.name}-api-vertical-scale"
  alarm_description = "Horizontal scaling is exhausted and the API still runs hot: step up the task size"
  alarm_rule = format(
    "(ALARM(\"%s\") OR ALARM(\"%s\")) AND ALARM(\"%s\")",
    aws_cloudwatch_metric_alarm.api_utilization_high["cpu"].alarm_name,
    aws_cloudwatch_metric_alarm.api_utilization_high["memory"].alarm_name,
    aws_cloudwatch_metric_alarm.api_at_max_tasks.alarm_name,
  )
  alarm_actions = [aws_lambda_function.vertical_scaler.arn]
}

data "archive_file" "vertical_scaler" {
  type        = "zip"
  source_file = "${path.module}/vertical_scaler/handler.py"
  output_path = "${path.module}/vertical_scaler.zip"
  # A fixed mode gives the same zip, and so no diff, on Windows and Linux checkouts.
  output_file_mode = "0644"
}

resource "aws_cloudwatch_log_group" "vertical_scaler" {
  name              = "/aws/lambda/${local.vertical_scaler_name}"
  retention_in_days = var.log_retention_days
}

resource "aws_lambda_function" "vertical_scaler" {
  function_name    = local.vertical_scaler_name
  description      = "Steps the API task up its size ladder when the vertical scaling alarm fires"
  role             = aws_iam_role.vertical_scaler.arn
  runtime          = "python3.13"
  handler          = "handler.handler"
  filename         = data.archive_file.vertical_scaler.output_path
  source_code_hash = data.archive_file.vertical_scaler.output_base64sha256
  timeout          = local.vertical_scaler_timeout_seconds

  environment {
    variables = {
      CLUSTER             = var.cluster_name
      SERVICE             = aws_ecs_service.api.name
      AT_MAX_TASKS_ALARM  = aws_cloudwatch_metric_alarm.api_at_max_tasks.alarm_name
      TASK_SIZE_PARAMETER = aws_ssm_parameter.api_task_size.name
      TASK_SIZES          = jsonencode(local.api_task_sizes)
    }
  }

  depends_on = [aws_cloudwatch_log_group.vertical_scaler, aws_iam_role_policy.vertical_scaler]
}

resource "aws_lambda_permission" "vertical_scale_alarm" {
  statement_id   = "AllowVerticalScaleAlarm"
  action         = "lambda:InvokeFunction"
  function_name  = aws_lambda_function.vertical_scaler.function_name
  principal      = "lambda.alarms.cloudwatch.amazonaws.com"
  source_arn     = aws_cloudwatch_composite_alarm.api_vertical_scale.arn
  source_account = data.aws_caller_identity.current.account_id
}

data "aws_iam_policy_document" "lambda_assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "vertical_scaler" {
  name               = local.vertical_scaler_name
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}

data "aws_iam_policy_document" "vertical_scaler" {
  statement {
    actions   = ["ecs:DescribeServices", "ecs:UpdateService"]
    resources = [aws_ecs_service.api.id]
  }

  # Task definition actions have no resource-level permissions.
  statement {
    actions   = ["ecs:DescribeTaskDefinition", "ecs:RegisterTaskDefinition"]
    resources = ["*"]
  }

  # A registered revision names the API's roles, which counts as passing them to ECS.
  statement {
    actions   = ["iam:PassRole"]
    resources = [aws_iam_role.execution["api"].arn, aws_iam_role.task.arn]

    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["ecs-tasks.amazonaws.com"]
    }
  }

  statement {
    actions   = ["ssm:PutParameter"]
    resources = [aws_ssm_parameter.api_task_size.arn]
  }

  # Re-arms the composite alarm when a step has to wait for a deployment to finish.
  statement {
    actions   = ["cloudwatch:SetAlarmState"]
    resources = [aws_cloudwatch_metric_alarm.api_at_max_tasks.arn]
  }

  statement {
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.vertical_scaler.arn}:*"]
  }
}

resource "aws_iam_role_policy" "vertical_scaler" {
  name   = "scale-api"
  role   = aws_iam_role.vertical_scaler.id
  policy = data.aws_iam_policy_document.vertical_scaler.json
}
