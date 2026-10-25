variable "name" {
  description = "Repository name, e.g. taskflow."
  type        = string
}

variable "releases_kept" {
  description = "Tagged images kept for rollback; older ones expire."
  type        = number
  default     = 30
}
