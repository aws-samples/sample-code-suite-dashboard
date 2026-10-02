variable "name" {
  description = "CodePipeline name."
  type        = string
}

variable "role_arn" {
  description = "IAM role for CodePipeline."
  type        = string
}

variable "artifact_bucket" {
  description = "S3 bucket name used as the artifact store."
  type        = string
}

variable "source_repo_name" {
  description = "CodeCommit repository name."
  type        = string
}

variable "source_branch" {
  description = "Branch to track in the source action."
  type        = string
  default     = "main"
}

variable "build_project_name" {
  description = "CodeBuild project name to invoke in the Build stage."
  type        = string
}
