output "repository_url" {
  description = "Registry path images are pushed to and pulled from."
  value       = aws_ecr_repository.this.repository_url
}

output "repository_arn" {
  description = "Repository ARN, for scoping pull permissions."
  value       = aws_ecr_repository.this.arn
}
