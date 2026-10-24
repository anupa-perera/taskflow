output "state_bucket" {
  description = "Backend bucket for the other stacks: -backend-config=\"bucket=<this>\"."
  value       = aws_s3_bucket.state.bucket
}

output "state_region" {
  description = "Backend region for the other stacks: -backend-config=\"region=<this>\"."
  value       = aws_s3_bucket.state.region
}
