variable "name" {
  description = "Prefix for resource names, e.g. taskflow-prod."
  type        = string
}

variable "vpc_id" {
  description = "VPC the hosts run in."
  type        = string
}

variable "subnet_ids" {
  description = "Private subnets, one per AZ, for the Auto Scaling Group."
  type        = list(string)
}

variable "instance_type" {
  description = "EC2 type for ECS hosts. Every task size must fit on one of these (ADR 0001)."
  type        = string
  default     = "t3.small"
}

variable "min_size" {
  description = "Minimum hosts; one per AZ keeps tasks running through an AZ or instance failure."
  type        = number
  default     = 2
}

variable "max_size" {
  description = "Ceiling for managed scaling."
  type        = number
  default     = 4
}

variable "root_volume_gb" {
  description = "Root EBS volume size; the ECS AMI's minimum is 30 GB."
  type        = number
  default     = 30
}

variable "host_log_retention_days" {
  description = "Retention for host logs shipped by the CloudWatch agent."
  type        = number
  default     = 14
}
