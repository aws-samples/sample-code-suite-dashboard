variable "name" {
  description = "CodeBuild project name."
  type        = string
}

variable "service_role_arn" {
  description = "IAM role ARN for the CodeBuild project."
  type        = string
}

variable "artifacts_type" {
  description = "Artifacts type."
  type        = string
  default     = "CODEPIPELINE"
}

variable "source_type" {
  description = "Source type."
  type        = string
  default     = "CODEPIPELINE"
}

variable "source_location" {
  description = "Source location (used when source_type != CODEPIPELINE)."
  type        = string
  default     = null
}

variable "buildspec" {
  description = "Inline buildspec or path within source. Null = let CodePipeline supply it."
  type        = string
  default     = null
}

variable "environment_image" {
  description = "CodeBuild environment image."
  type        = string
  default     = "aws/codebuild/amazonlinux-x86_64-standard:5.0"
}

variable "environment_compute_type" {
  description = "CodeBuild compute type."
  type        = string
  default     = "BUILD_GENERAL1_SMALL"
}

variable "privileged_mode" {
  description = "Whether to run the build container in privileged mode (needed for Docker)."
  type        = bool
  default     = false
}

variable "environment_variables" {
  description = "Map of environment variables passed to the build."
  type        = map(string)
  default     = {}
}

variable "log_group_name" {
  description = "CloudWatch log group name. If null, defaults to /aws/codebuild/<name>."
  type        = string
  default     = null
}

variable "log_retention_days" {
  description = "Retention in days for the CodeBuild log group."
  type        = number
  default     = 14
}
