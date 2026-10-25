terraform {
  required_version = ">= 1.10, < 2.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.70"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.9"
    }
  }

  # Bucket and region come from the bootstrap stack's outputs at init time: the bucket name embeds
  # the account id (kept out of the public repo) and backend blocks cannot read variables.
  #   terraform init -backend-config="bucket=<state_bucket>" -backend-config="region=<state_region>"
  backend "s3" {
    key          = "prod/terraform.tfstate"
    encrypt      = true
    use_lockfile = true
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = "taskflow"
      Environment = "prod"
      ManagedBy   = "terraform"
    }
  }
}
