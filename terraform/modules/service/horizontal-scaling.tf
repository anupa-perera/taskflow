# Horizontal scaling: ECS Service Auto Scaling adds and removes API tasks to hold average utilization
# near the target, and the capacity provider adds hosts when new tasks have no room.

locals {
  # One task per AZ at minimum. At two tasks per host (the ENI limit), four tasks fill two hosts, and
  # a deployment of four tasks fills the ASG's maximum of four.
  min_task_count = 2
  max_task_count = 4

  # Below the vertical scaling threshold, so adding tasks is always tried before resizing them.
  target_utilization_percent = 70
  scale_out_cooldown_seconds = 60
  # Slower to remove tasks than to add them, so a short lull does not drop capacity under load.
  scale_in_cooldown_seconds = 300
}

resource "aws_appautoscaling_target" "api" {
  service_namespace  = "ecs"
  scalable_dimension = "ecs:service:DesiredCount"
  resource_id        = "service/${var.cluster_name}/${aws_ecs_service.api.name}"
  min_capacity       = local.min_task_count
  max_capacity       = local.max_task_count
}

# Memory as well as CPU, so memory pressure also reaches the maximum count that vertical scaling
# waits for. With two policies, a scale-out needs either one and a scale-in needs both.
resource "aws_appautoscaling_policy" "api" {
  for_each = {
    cpu    = "ECSServiceAverageCPUUtilization"
    memory = "ECSServiceAverageMemoryUtilization"
  }

  name               = "${var.name}-api-${each.key}"
  policy_type        = "TargetTrackingScaling"
  service_namespace  = aws_appautoscaling_target.api.service_namespace
  scalable_dimension = aws_appautoscaling_target.api.scalable_dimension
  resource_id        = aws_appautoscaling_target.api.resource_id

  target_tracking_scaling_policy_configuration {
    target_value       = local.target_utilization_percent
    scale_out_cooldown = local.scale_out_cooldown_seconds
    scale_in_cooldown  = local.scale_in_cooldown_seconds

    predefined_metric_specification {
      predefined_metric_type = each.value
    }
  }
}
