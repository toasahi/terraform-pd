output "repository_urls" {
  description = "Repository URLs keyed by repository name."
  value       = { for name, repo in aws_ecr_repository.main : name => repo.repository_url }
}

output "repository_arns" {
  description = "Repository ARNs keyed by repository name."
  value       = { for name, repo in aws_ecr_repository.main : name => repo.arn }
}
