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

module "database" {
  source = "../../modules/database"

  name       = local.name
  vpc_id     = module.network.vpc_id
  subnet_ids = module.network.private_subnet_ids

  deletion_protection = var.database_deletion_protection
  final_snapshot      = var.database_final_snapshot
}

module "ecs_cluster" {
  source = "../../modules/ecs-cluster"

  name       = local.name
  vpc_id     = module.network.vpc_id
  subnet_ids = module.network.private_subnet_ids
}
