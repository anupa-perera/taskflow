output "address" {
  description = "Hostname clients connect to (verified against the RDS CA bundle)."
  value       = aws_db_instance.this.address
}

output "port" {
  description = "PostgreSQL port."
  value       = aws_db_instance.this.port
}

output "database_name" {
  description = "Database the application uses."
  value       = aws_db_instance.this.db_name
}

output "security_group_id" {
  description = "Database security group; the service module adds the task ingress rule to it."
  value       = aws_security_group.db.id
}

output "master_secret_arn" {
  description = "RDS-managed master credentials (username, password); for the migration task only."
  value       = aws_db_instance.this.master_user_secret[0].secret_arn
}

output "app_secret_arn" {
  description = "Restricted API credentials (username, password)."
  value       = aws_secretsmanager_secret.app.arn
}

output "identifier" {
  description = "RDS instance identifier, the DBInstanceIdentifier CloudWatch dimension."
  value       = aws_db_instance.this.identifier
}
