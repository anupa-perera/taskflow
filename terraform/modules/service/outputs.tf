output "alb_dns_name" {
  description = "Public hostname of the ALB."
  value       = aws_lb.this.dns_name
}

output "alb_arn_suffix" {
  description = "ALB identifier used in CloudWatch metric dimensions."
  value       = aws_lb.this.arn_suffix
}

output "target_group_arn_suffix" {
  description = "Target group identifier used in CloudWatch metric dimensions."
  value       = aws_lb_target_group.api.arn_suffix
}

output "service_name" {
  description = "ECS service running the API."
  value       = aws_ecs_service.api.name
}

output "api_task_definition_arn" {
  description = "Latest API task definition revision."
  value       = aws_ecs_task_definition.api.arn
}

output "migrate_task_definition_arn" {
  description = "Latest migration task definition revision."
  value       = aws_ecs_task_definition.migrate.arn
}

output "task_security_group_id" {
  description = "Security group of the API and migration tasks."
  value       = aws_security_group.tasks.id
}

output "log_group_name" {
  description = "Log group of the API and migration tasks."
  value       = aws_cloudwatch_log_group.tasks.name
}
