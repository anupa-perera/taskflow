variable "aws_region" {
  description = "Region for the state bucket and every TaskFlow resource."
  type        = string
  default     = "ap-south-1"
}

variable "noncurrent_state_retention_days" {
  description = "How long superseded state versions are kept for rollback."
  type        = number
  default     = 90
}
