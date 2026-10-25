output "vpc_id" {
  description = "ID of the TaskFlow VPC."
  value       = module.network.vpc_id
}

output "database_address" {
  description = "RDS hostname."
  value       = module.database.address
}

output "database_master_secret_arn" {
  description = "Secrets Manager ARN of the RDS-managed master credentials (migration task only)."
  value       = module.database.master_secret_arn
}

output "database_app_secret_arn" {
  description = "Secrets Manager ARN of the restricted API credentials."
  value       = module.database.app_secret_arn
}

output "ecs_cluster_name" {
  description = "ECS cluster name."
  value       = module.ecs_cluster.cluster_name
}

output "ecs_autoscaling_group_name" {
  description = "Auto Scaling Group of the ECS hosts."
  value       = module.ecs_cluster.autoscaling_group_name
}

output "ecr_repository_url" {
  description = "Registry path CI pushes images to."
  value       = module.ecr.repository_url
}

output "alb_dns_name" {
  description = "Public hostname of the API."
  value       = module.service.alb_dns_name
}

output "ecs_service_name" {
  description = "ECS service running the API."
  value       = module.service.service_name
}

output "api_task_definition_arn" {
  description = "API revision scripts/deploy.sh rolls out."
  value       = module.service.api_task_definition_arn
}

output "migrate_task_definition_arn" {
  description = "Migration revision scripts/deploy.sh runs before the rollout."
  value       = module.service.migrate_task_definition_arn
}

output "vertical_scaling" {
  description = "Vertical scaling alarm, Lambda and the SSM parameter holding the API task size."
  value       = module.service.vertical_scaling
}

output "dashboard_name" {
  description = "CloudWatch dashboard of the service."
  value       = aws_cloudwatch_dashboard.this.dashboard_name
}
