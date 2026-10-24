terraform {
  # 1.10 introduced S3-native state locking (use_lockfile), which the prod backend relies on.
  required_version = ">= 1.10, < 2.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.70"
    }
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project   = "taskflow"
      Stack     = "bootstrap"
      ManagedBy = "terraform"
    }
  }
}
