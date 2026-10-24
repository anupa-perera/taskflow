# 0004. Terraform state in S3 with S3-native locking

- Status: Accepted
- Date: 2026-10-24

## Context

The brief requires remote Terraform state, "for example S3 with a DynamoDB lock table", never
committed to git. State contains secrets in plain text, and two concurrent applies against the same
state can corrupt it, so it needs locking. Terraform 1.10 added S3-native locking (a lock object
written next to the state with a conditional write), and Terraform 1.11 deprecated DynamoDB-based
locking.

The state bucket must exist before any stack can use it, so the stack that creates it has to start
with local state. That state could be migrated into the bucket afterwards, but then a broken or
deleted bucket would also take away the state needed to repair or remove it.

## Decision

- A separate `terraform/bootstrap` stack, applied once by hand, creates the state bucket. Its own
  state stays local on purpose, as a recovery and deletion boundary. The bucket is versioned,
  encrypted with SSE-S3, blocks all public access, denies non-TLS requests, expires superseded
  versions after 90 days and has `prevent_destroy` set.
- The bucket uses SSE-S3 rather than a customer-managed KMS key; this is a documented, expiring
  exception in `.trivyignore.yaml` (Trivy AWS-0132).
- Every other stack uses the `s3` backend with `use_lockfile = true` instead of a DynamoDB table.
- The bucket name contains the AWS account id, so it and the region are passed at `terraform init`
  time with `-backend-config` (from the bootstrap stack's outputs) rather than committed to the
  public repository.
- Terraform runs from the pinned `hashicorp/terraform:1.17.0` image locally and in CI.

## Consequences

- One fewer resource than the brief's example, and no deprecated locking path.
- The bootstrap stack's own state is a local, git-ignored file. If it is lost, the bucket keeps
  working; the state can be rebuilt with `terraform import`, which is acceptable for a single bucket
  that is never meant to change.
- `terraform destroy` on the prod stack leaves the state bucket in place. Deleting it is a deliberate,
  manual step (remove `prevent_destroy`, empty the bucket, destroy the bootstrap stack).
- Versioning means a corrupted or wrongly applied state can be restored from a previous version.
