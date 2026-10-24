variable "name" {
  description = "Prefix for resource names, e.g. taskflow-prod."
  type        = string
}

variable "vpc_id" {
  description = "VPC the database lives in."
  type        = string
}

variable "subnet_ids" {
  description = "Private subnets, one per AZ, for the DB subnet group."
  type        = list(string)
}

variable "engine_version" {
  description = "PostgreSQL major version; RDS applies minor upgrades in the maintenance window."
  type        = string
  default     = "17"
}

variable "instance_class" {
  description = "RDS instance size."
  type        = string
  default     = "db.t4g.micro"
}

variable "allocated_storage_gb" {
  description = "Initial gp3 storage. 20 GB is the gp3 minimum."
  type        = number
  default     = 20
}

variable "max_allocated_storage_gb" {
  description = "Ceiling for storage autoscaling, so a runaway table cannot grow the bill without limit."
  type        = number
  default     = 50
}

variable "database_name" {
  description = "Database created on the instance."
  type        = string
  default     = "taskflow"
}

variable "master_username" {
  description = "RDS master user; only the migration task uses it."
  type        = string
  default     = "taskflow_admin"
}

variable "app_username" {
  description = "Restricted role the API connects as; created by the migration task."
  type        = string
  default     = "taskflow_app"
}

variable "backup_retention_days" {
  description = "Days of automated backups kept for point-in-time restore."
  type        = number
  default     = 7
}

variable "log_retention_days" {
  description = "Retention for the PostgreSQL log group exported to CloudWatch."
  type        = number
  default     = 7
}

variable "deletion_protection" {
  description = "Refuse deletes. Only scripts/teardown.sh turns this off, deliberately."
  type        = bool
  default     = true
}

variable "final_snapshot" {
  description = "Take a final snapshot when the instance is deleted."
  type        = bool
  default     = true
}
