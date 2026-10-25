locals {
  # Ansible's dynamic inventory selects hosts by this tag (aws_ec2 plugin).
  host_role_tag = "ecs-host"

  https_port = 443
  # Keep half the hosts serving while an instance refresh replaces the others.
  refresh_min_healthy_percent = 50
  # Managed scaling aims for hosts fully used by placed tasks; any pending task triggers a scale-out.
  capacity_target_percent = 100
  # Host memory and disk metrics from the CloudWatch agent (Ansible) land here.
  host_metrics_namespace = "TaskFlow/ECSHosts"
}

# AWS publishes the current ECS-optimized AMI here; a new AMI shows up as a launch template change
# in the plan and rolls out through the ASG instance refresh.
data "aws_ssm_parameter" "ecs_ami" {
  name = "/aws/service/ecs/optimized-ami/amazon-linux-2023/recommended/image_id"
}

# Container Insights writes here; created first so it never gets the default "never expire".
resource "aws_cloudwatch_log_group" "container_insights" {
  name              = "/aws/ecs/containerinsights/${var.name}/performance"
  retention_in_days = var.host_log_retention_days
}

resource "aws_ecs_cluster" "this" {
  name = var.name

  # Provides the task-count and resource metrics the dashboard and scaling alarms use.
  setting {
    name  = "containerInsights"
    value = "enabled"
  }

  depends_on = [aws_cloudwatch_log_group.container_insights]
}

resource "aws_cloudwatch_log_group" "hosts" {
  name              = "/taskflow/ec2/${var.name}"
  retention_in_days = var.host_log_retention_days
}

data "aws_iam_policy_document" "ec2_assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "host" {
  name               = "${var.name}-ecs-host"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
}

# SSM replaces SSH: shell sessions and Ansible runs both go through Session Manager.
resource "aws_iam_role_policy_attachment" "host" {
  for_each = toset([
    "arn:aws:iam::aws:policy/service-role/AmazonEC2ContainerServiceforEC2Role",
    "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore",
  ])

  role       = aws_iam_role.host.name
  policy_arn = each.value
}

# The CloudWatch agent, scoped to this cluster's host log group and metric namespace instead of
# CloudWatchAgentServerPolicy (any log group, any namespace).
data "aws_iam_policy_document" "cloudwatch_agent" {
  statement {
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents", "logs:DescribeLogStreams"]
    resources = ["${aws_cloudwatch_log_group.hosts.arn}:*"]
  }

  # PutMetricData has no resource-level permissions; the namespace condition is the scope.
  statement {
    actions   = ["cloudwatch:PutMetricData"]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "cloudwatch:namespace"
      values   = [local.host_metrics_namespace]
    }
  }

  # Resolves the AutoScalingGroupName dimension the agent adds to every metric.
  statement {
    actions   = ["ec2:DescribeTags"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "cloudwatch_agent" {
  name   = "cloudwatch-agent"
  role   = aws_iam_role.host.id
  policy = data.aws_iam_policy_document.cloudwatch_agent.json
}

resource "aws_iam_instance_profile" "host" {
  name = "${var.name}-ecs-host"
  role = aws_iam_role.host.name
}

# With awsvpc, tasks have their own security groups, so the host accepts no inbound traffic. It only
# calls AWS APIs (ECS, ECR, SSM, CloudWatch) and package repositories, all over HTTPS.
resource "aws_security_group" "host" {
  name        = "${var.name}-ecs-host"
  description = "ECS hosts: no inbound; HTTPS out to AWS APIs and package repositories"
  vpc_id      = var.vpc_id

  egress {
    description = "AWS APIs and package repositories over HTTPS"
    from_port   = local.https_port
    to_port     = local.https_port
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.name}-ecs-host" }
}

resource "aws_launch_template" "host" {
  name_prefix   = "${var.name}-ecs-host-"
  image_id      = data.aws_ssm_parameter.ecs_ami.insecure_value
  instance_type = var.instance_type

  iam_instance_profile {
    arn = aws_iam_instance_profile.host.arn
  }

  vpc_security_group_ids = [aws_security_group.host.id]

  # IMDSv2 only, and a hop limit of 1 so containers cannot reach the host's metadata (and its role).
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  block_device_mappings {
    device_name = "/dev/xvda"

    ebs {
      volume_size           = var.root_volume_gb
      volume_type           = "gp3"
      encrypted             = true
      delete_on_termination = true
    }
  }

  # Only what joining the cluster needs, so a host the ASG adds later can take tasks at once.
  # Everything else on the host is Ansible's job (ADR 0001).
  user_data = base64encode(<<-EOT
    #!/bin/bash
    cat >> /etc/ecs/ecs.config <<'CONFIG'
    ECS_CLUSTER=${aws_ecs_cluster.this.name}
    ECS_AWSVPC_BLOCK_IMDS=true
    CONFIG
  EOT
  )

  tag_specifications {
    resource_type = "instance"
    tags = {
      Name = "${var.name}-ecs-host"
      Role = local.host_role_tag
    }
  }

  tag_specifications {
    resource_type = "volume"
    tags          = { Name = "${var.name}-ecs-host" }
  }
}

resource "aws_autoscaling_group" "hosts" {
  name_prefix         = "${var.name}-ecs-hosts-"
  vpc_zone_identifier = var.subnet_ids
  min_size            = var.min_size
  max_size            = var.max_size

  launch_template {
    id      = aws_launch_template.host.id
    version = aws_launch_template.host.latest_version
  }

  # Replaces hosts in batches when the launch template changes (e.g. a new AMI); managed draining
  # moves tasks off each host before it goes.
  instance_refresh {
    strategy = "Rolling"

    preferences {
      min_healthy_percentage = local.refresh_min_healthy_percent
    }
  }

  # Required on ASGs that ECS capacity providers manage.
  tag {
    key                 = "AmazonECSManaged"
    value               = "true"
    propagate_at_launch = true
  }

  # Hosts register with ECS about a minute after launch. Not waiting for them lets the capacity
  # provider below be created first, so every host registers as part of it; a host that registers
  # before the capacity provider exists can never run tasks placed through it.
  wait_for_capacity_timeout = "0"

  # The capacity provider sets the desired count; Terraform must not reset it on every apply.
  lifecycle {
    ignore_changes = [desired_capacity]
  }

  # Hosts need their permissions at boot (ECS registration, SSM), and on destroy must go first.
  depends_on = [aws_iam_role_policy_attachment.host, aws_iam_role_policy.cloudwatch_agent]
}

resource "aws_ecs_capacity_provider" "hosts" {
  name = var.name

  auto_scaling_group_provider {
    auto_scaling_group_arn = aws_autoscaling_group.hosts.arn
    managed_draining       = "ENABLED"

    managed_scaling {
      status          = "ENABLED"
      target_capacity = local.capacity_target_percent
    }
  }
}

resource "aws_ecs_cluster_capacity_providers" "this" {
  cluster_name       = aws_ecs_cluster.this.name
  capacity_providers = [aws_ecs_capacity_provider.hosts.name]

  default_capacity_provider_strategy {
    capacity_provider = aws_ecs_capacity_provider.hosts.name
    weight            = 1
  }
}
