locals {
  name = "taskflow-prod"
}

module "network" {
  source = "../../modules/network"

  name = local.name
  # AZ names must belong to var.aws_region.
  availability_zones = {
    "ap-south-1a" = 0
    "ap-south-1b" = 1
  }
}
