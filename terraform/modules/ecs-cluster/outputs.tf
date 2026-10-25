output "cluster_name" {
  description = "ECS cluster name."
  value       = aws_ecs_cluster.this.name
}

output "cluster_arn" {
  description = "ECS cluster ARN."
  value       = aws_ecs_cluster.this.arn
}

output "capacity_provider_name" {
  description = "Capacity provider the service must use (capacity_provider_strategy)."
  value       = aws_ecs_capacity_provider.hosts.name
  # A service can only use a capacity provider once it is associated with the cluster.
  depends_on = [aws_ecs_cluster_capacity_providers.this]
}

output "host_security_group_id" {
  description = "Security group of the ECS hosts."
  value       = aws_security_group.host.id
}

output "host_log_group_name" {
  description = "Log group the CloudWatch agent ships host logs to."
  value       = aws_cloudwatch_log_group.hosts.name
}

output "host_role_tag" {
  description = "Value of the Role tag on hosts, used by the Ansible dynamic inventory."
  value       = local.host_role_tag
}

output "autoscaling_group_name" {
  description = "Auto Scaling Group of the ECS hosts."
  value       = aws_autoscaling_group.hosts.name
}
