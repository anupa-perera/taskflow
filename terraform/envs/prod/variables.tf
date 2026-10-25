variable "aws_region" {
  description = "Region for every TaskFlow resource; must match the state bucket's region."
  type        = string
  default     = "ap-south-1"
}

variable "database_deletion_protection" {
  description = "Keep on. scripts/teardown.sh sets it to false for a deliberate teardown."
  type        = bool
  default     = true
}

variable "database_final_snapshot" {
  description = "Snapshot the database when it is deleted. scripts/teardown.sh skips it for pauses."
  type        = bool
  default     = true
}

variable "image_tag" {
  description = "Commit SHA of the TaskFlow image to register task definitions for."
  type        = string

  validation {
    condition     = can(regex("^[0-9a-f]{7,40}$", var.image_tag))
    error_message = "image_tag must be a commit SHA (7-40 lowercase hex characters), never \"latest\"."
  }
}
