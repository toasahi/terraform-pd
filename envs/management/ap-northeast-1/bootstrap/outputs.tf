output "state_bucket_name" {
  description = "Terraform state bucket."
  value       = aws_s3_bucket.state.bucket
}
