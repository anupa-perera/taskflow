variable "name" {
  description = "Prefix for resource names, e.g. taskflow-prod."
  type        = string
}

variable "vpc_id" {
  description = "VPC the ALB and tasks run in."
  type        = string
}

variable "public_subnet_ids" {
  description = "Subnets for the internet-facing ALB, one per AZ."
  type        = list(string)
}

variable "private_subnet_ids" {
  description = "Subnets for task ENIs, one per AZ."
  type        = list(string)
}

variable "cluster_arn" {
  description = "ECS cluster the service runs in."
  type        = string
}

variable "cluster_name" {
  description = "Name of that cluster, for Service Auto Scaling and CloudWatch dimensions."
  type        = string
}

variable "capacity_provider_name" {
  description = "Capacity provider that places tasks on the cluster's hosts."
  type        = string
}

variable "repository_url" {
  description = "ECR repository the image is pulled from."
  type        = string
}

variable "repository_arn" {
  description = "ECR repository ARN, for scoping pull permissions."
  type        = string
}

variable "image_tag" {
  description = "Commit SHA of the image both task definitions run."
  type        = string
}

variable "database" {
  description = "Connection details and secrets from the database module."
  type = object({
    address           = string
    port              = number
    name              = string
    security_group_id = string
    master_secret_arn = string
    app_secret_arn    = string
  })
}

variable "desired_count" {
  description = "API tasks to start with; Service Auto Scaling owns the count afterwards."
  type        = number
  default     = 2
}

variable "log_level" {
  description = "API log level (pino)."
  type        = string
  default     = "info"
}

variable "log_retention_days" {
  description = "Retention for API and migration task logs."
  type        = number
  default     = 30
}
