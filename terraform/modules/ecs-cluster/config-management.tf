# Ansible reaches the hosts through Session Manager (amazon.aws.aws_ssm), which moves module files
# through S3. The controller uploads them; hosts download over presigned URLs, so hosts need no
# S3 permissions. Objects are transient, so they expire after a day.

data "aws_caller_identity" "current" {}

locals {
  transfer_expiry_days = 1
}

resource "aws_s3_bucket" "ansible_transfer" {
  # Fixed name, so the Ansible inventory can derive it from the account ID without a lookup.
  bucket = "${var.name}-ansible-${data.aws_caller_identity.current.account_id}"
  # Holds nothing worth keeping, so a teardown may delete it with its contents.
  force_destroy = true
}

resource "aws_s3_bucket_public_access_block" "ansible_transfer" {
  bucket                  = aws_s3_bucket.ansible_transfer.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "ansible_transfer" {
  bucket = aws_s3_bucket.ansible_transfer.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "ansible_transfer" {
  bucket = aws_s3_bucket.ansible_transfer.id

  rule {
    id     = "expire-transfers"
    status = "Enabled"
    filter {}

    expiration {
      days = local.transfer_expiry_days
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = local.transfer_expiry_days
    }
  }
}

data "aws_iam_policy_document" "ansible_transfer_tls_only" {
  statement {
    sid     = "DenyInsecureTransport"
    effect  = "Deny"
    actions = ["s3:*"]
    resources = [
      aws_s3_bucket.ansible_transfer.arn,
      "${aws_s3_bucket.ansible_transfer.arn}/*",
    ]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "ansible_transfer" {
  bucket = aws_s3_bucket.ansible_transfer.id
  policy = data.aws_iam_policy_document.ansible_transfer_tls_only.json

  depends_on = [aws_s3_bucket_public_access_block.ansible_transfer]
}
