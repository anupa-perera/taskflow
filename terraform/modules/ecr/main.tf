locals {
  # Untagged images are leftovers of interrupted pushes; nothing can deploy them.
  untagged_expiry_days = 1
}

resource "aws_ecr_repository" "this" {
  name = var.name
  # A commit SHA always names the same image, so a deployed tag can never be overwritten.
  image_tag_mutability = "IMMUTABLE"
  # Every image is rebuilt from its commit, so a teardown may delete them with the repository.
  force_delete = true

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "AES256"
  }
}

resource "aws_ecr_lifecycle_policy" "this" {
  repository = aws_ecr_repository.this.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Expire untagged images"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = local.untagged_expiry_days
        }
        action = { type = "expire" }
      },
      {
        rulePriority = 2
        description  = "Keep the most recent releases for rollback"
        selection = {
          tagStatus   = "any"
          countType   = "imageCountMoreThan"
          countNumber = var.releases_kept
        }
        action = { type = "expire" }
      },
    ]
  })
}
