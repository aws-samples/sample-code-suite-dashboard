output "pipelines" {
  description = "Map of sample pipeline names keyed by sample key."
  value       = { for k, p in module.pipeline : k => p.name }
}

output "repos" {
  description = "Map of CodeCommit repo HTTPS clone URLs keyed by sample key."
  value       = { for k, r in aws_codecommit_repository.this : k => r.clone_url_http }
}

output "artifact_bucket" {
  description = "Shared artifact bucket for every sample pipeline."
  value       = aws_s3_bucket.artifacts.bucket
}
