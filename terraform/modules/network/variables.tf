variable "name" {
  description = "Prefix for resource names, e.g. taskflow-prod."
  type        = string
}

variable "vpc_cidr" {
  description = "IPv4 range for the VPC. Must be a /16: each subnet takes a /24 out of it."
  type        = string
  default     = "10.0.0.0/16"

  validation {
    condition     = can(cidrnetmask(var.vpc_cidr)) && endswith(var.vpc_cidr, "/16")
    error_message = "vpc_cidr must be a valid /16, e.g. 10.0.0.0/16."
  }
}

variable "availability_zones" {
  description = <<-EOT
    AZ name to subnet number, e.g. { "ap-south-1a" = 0, "ap-south-1b" = 1 }. Keyed by name, so adding
    or removing an AZ never moves the others' subnets.
  EOT
  type        = map(number)

  validation {
    condition     = length(var.availability_zones) >= 2
    error_message = "Use at least two availability zones so one AZ failure cannot take the service down."
  }

  validation {
    condition = (
      length(distinct(values(var.availability_zones))) == length(var.availability_zones)
      && alltrue([
        for n in values(var.availability_zones) :
        n >= 0 && n < local.private_netnum_offset && floor(n) == n
      ])
    )
    error_message = "Subnet numbers must be distinct whole numbers below the private subnet offset (10)."
  }
}

variable "flow_log_retention_days" {
  description = "How long rejected-traffic flow logs are kept."
  type        = number
  default     = 7
}
