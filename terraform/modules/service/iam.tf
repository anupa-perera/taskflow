data "aws_caller_identity" "current" {}

data "aws_region" "current" {}

data "aws_iam_policy_document" "ecs_tasks_assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }

    # Only ECS in this account may use the roles (confused-deputy protection).
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }

    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = ["arn:aws:ecs:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:*"]
    }
  }
}

# The ECS agent uses an execution role to start a task: pull the image, fetch its secrets, create
# its log stream. One per task family, so only the migration task can read the master secret.
resource "aws_iam_role" "execution" {
  for_each = local.task_secret_arns

  name               = "${var.name}-${each.key}-execution"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume.json
}

data "aws_iam_policy_document" "execution" {
  for_each = local.task_secret_arns

  # GetAuthorizationToken has no resource-level permissions.
  statement {
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  statement {
    actions   = ["ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer", "ecr:BatchCheckLayerAvailability"]
    resources = [var.repository_arn]
  }

  statement {
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.tasks.arn}:log-stream:${each.key}/*"]
  }

  statement {
    actions   = ["secretsmanager:GetSecretValue"]
    resources = each.value
  }
}

resource "aws_iam_role_policy" "execution" {
  for_each = local.task_secret_arns

  name   = "start-task"
  role   = aws_iam_role.execution[each.key].id
  policy = data.aws_iam_policy_document.execution[each.key].json
}

# What the application code itself may call. TaskFlow calls no AWS APIs, so it grants nothing.
resource "aws_iam_role" "task" {
  name               = "${var.name}-task"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume.json
}
