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

module "ecr" {
  source = "../../modules/ecr"

  name = "taskflow"
}

module "service" {
  source = "../../modules/service"

  name               = local.name
  vpc_id             = module.network.vpc_id
  public_subnet_ids  = module.network.public_subnet_ids
  private_subnet_ids = module.network.private_subnet_ids

  cluster_arn            = module.ecs_cluster.cluster_arn
  cluster_name           = module.ecs_cluster.cluster_name
  capacity_provider_name = module.ecs_cluster.capacity_provider_name

  repository_url = module.ecr.repository_url
  repository_arn = module.ecr.repository_arn
  image_tag      = var.image_tag

  database = {
    address           = module.database.address
    port              = module.database.port
    name              = module.database.database_name
    security_group_id = module.database.security_group_id
    master_secret_arn = module.database.master_secret_arn
    app_secret_arn    = module.database.app_secret_arn
  }
}
