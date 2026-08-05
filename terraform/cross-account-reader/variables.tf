variable "region" {
  description = "Region to deploy the IAM role in. IAM is global so this just sets the provider context; pick anywhere."
  type        = string
  default     = "us-east-1"
}

variable "central_account_id" {
  description = "The 12-digit AWS account ID where the dashboard's stats Lambda runs. No default — must be provided by the operator."
  type        = string
  validation {
    condition     = can(regex("^[0-9]{12}$", var.central_account_id))
    error_message = "central_account_id must be a 12-digit AWS account ID."
  }
}

variable "central_lambda_role_arn" {
  description = <<-EOT
    Optional override for the central stats Lambda role ARN that this role
    trusts. When left empty (default), it is computed as:
      arn:aws:iam::<central_account_id>:role/pipeline-dashboard-stats-lambda-role
    Only override this if you renamed the role in terraform/dashboard-backend.
  EOT
  type        = string
  default     = ""
}

variable "role_name" {
  description = "Name of the IAM role to create in this target account."
  type        = string
  default     = "PipelineDashboardReader"
}
