locals {
  dashboard_period_seconds = 60
  widget_width             = 8
  widget_height            = 6

  alb         = ["LoadBalancer", module.service.alb_arn_suffix]
  ecs_service = ["ClusterName", module.ecs_cluster.cluster_name, "ServiceName", module.service.service_name]
  db          = ["DBInstanceIdentifier", module.database.identifier]
  hosts       = ["AutoScalingGroupName", module.ecs_cluster.autoscaling_group_name]

  # CloudWatch places widgets without x and y in reading order.
  dashboard_widgets = [
    {
      title   = "ALB requests"
      stat    = "Sum"
      metrics = [concat(["AWS/ApplicationELB", "RequestCount"], local.alb)]
    },
    {
      title = "ALB 5xx responses"
      stat  = "Sum"
      metrics = [
        concat(["AWS/ApplicationELB", "HTTPCode_Target_5XX_Count"], local.alb, [{ label = "From tasks" }]),
        concat(["AWS/ApplicationELB", "HTTPCode_ELB_5XX_Count"], local.alb, [{ label = "From the ALB" }]),
      ]
    },
    {
      title = "Target response time (seconds)"
      metrics = [
        concat(["AWS/ApplicationELB", "TargetResponseTime"], local.alb, [{ stat = "p50", label = "p50" }]),
        concat(["AWS/ApplicationELB", "TargetResponseTime"], local.alb, [{ stat = "p99", label = "p99" }]),
      ]
    },
    {
      title = "API CPU and memory utilization (%)"
      stat  = "Average"
      metrics = [
        concat(["AWS/ECS", "CPUUtilization"], local.ecs_service),
        concat(["AWS/ECS", "MemoryUtilization"], local.ecs_service),
      ]
    },
    {
      title = "API tasks and hosts"
      stat  = "Maximum"
      metrics = [
        concat(["ECS/ContainerInsights", "RunningTaskCount"], local.ecs_service),
        concat(["ECS/ContainerInsights", "DesiredTaskCount"], local.ecs_service),
        ["ECS/ContainerInsights", "ContainerInstanceCount", "ClusterName", module.ecs_cluster.cluster_name],
      ]
    },
    {
      # Steps up with each task added (horizontal) and each size change (vertical).
      title = "API reserved CPU units and memory (MiB)"
      stat  = "Maximum"
      metrics = [
        concat(["ECS/ContainerInsights", "CpuReserved"], local.ecs_service),
        concat(["ECS/ContainerInsights", "MemoryReserved"], local.ecs_service),
      ]
    },
    {
      title   = "RDS CPU utilization (%)"
      stat    = "Average"
      metrics = [concat(["AWS/RDS", "CPUUtilization"], local.db)]
    },
    {
      title   = "RDS connections"
      stat    = "Maximum"
      metrics = [concat(["AWS/RDS", "DatabaseConnections"], local.db)]
    },
    {
      title = "Host memory and root disk used (%)"
      stat  = "Maximum"
      metrics = [
        concat([module.ecs_cluster.host_metrics_namespace, "mem_used_percent"], local.hosts),
        concat([module.ecs_cluster.host_metrics_namespace, "disk_used_percent"], local.hosts),
      ]
    },
  ]
}

resource "aws_cloudwatch_dashboard" "this" {
  dashboard_name = local.name
  dashboard_body = jsonencode({
    widgets = [for widget in local.dashboard_widgets : {
      type   = "metric"
      width  = local.widget_width
      height = local.widget_height
      properties = merge(widget, {
        region = var.aws_region
        period = local.dashboard_period_seconds
        view   = "timeSeries"
      })
    }]
  })
}
