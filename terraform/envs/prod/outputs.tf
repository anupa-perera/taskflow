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
