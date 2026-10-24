variable "aws_region" {
  description = "Region for every TaskFlow resource; must match the state bucket's region."
  type        = string
  default     = "ap-south-1"
}
