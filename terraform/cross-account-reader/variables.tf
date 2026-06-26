variable "region" {
  description = "Region to deploy the IAM role in. IAM is global so this just sets the provider context; pick anywhere."
  type        = string
  default     = "us-east-1"
}

variable "central_account_id" {
  description = "The 12-digit AWS account ID where the dashboard's stats Lambda runs."
  type        = string
  default     = "795065187596"
  validation {
    condition     = can(regex("^[0-9]{12}$", var.central_account_id))
    error_message = "central_account_id must be a 12-digit AWS account ID."
  }
}

variable "central_lambda_role_arn" {
  description = "ARN of the central account's stats Lambda role. The created role's trust policy is locked down to this principal."
  type        = string
  default     = "arn:aws:iam::795065187596:role/pipeline-dashboard-stats-lambda-role"
}

variable "role_name" {
  description = "Name of the IAM role to create in this target account."
  type        = string
  default     = "PipelineDashboardReader"
}
