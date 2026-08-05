variable "aws_region" {
  description = "AWS region."
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Project name used for resource naming."
  type        = string
  default     = "pipeline-dashboard"
  validation {
    condition     = can(regex("^[a-z0-9-]+$", var.project_name))
    error_message = "project_name must be lowercase letters, numbers, and hyphens."
  }
}

variable "hosting_bucket" {
  description = <<-EOT
    Optional S3 bucket name that hosts a `version.json` marker file for the
    deployed dashboard build. The stats + enrichment Lambdas read this to
    surface the deployed version alongside pipeline data. Leave blank (the
    default) if you run the dashboard locally — the code falls back to a
    placeholder.
  EOT
  type        = string
  default     = ""
}

variable "tracked_accounts" {
  description = <<-EOT
    Real, cross-account entries the dashboard should aggregate. Each entry
    needs a role_arn pointing at the PipelineDashboardReader role in the
    target account. Use `make track-account PROFILE=<...> ALIAS=<...>` to
    create that role and emit a paste-ready snippet.
  EOT
  type = list(object({
    account_id = string
    alias      = string
    region     = optional(string, "us-east-1")
    role_arn   = optional(string)
    synthetic  = optional(bool, false)
  }))
  default = []
}

variable "synthetic_account_count" {
  description = <<-EOT
    How many synthetic (non-real) accounts to auto-generate so the
    multi-account UI has volume to render. Synthetic accounts clone
    pipelines from the local account, perturb their statuses, and re-tag
    them under a fake account ID. Set to 0 for production deployments.
  EOT
  type        = number
  default     = 0
  validation {
    condition     = var.synthetic_account_count >= 0 && var.synthetic_account_count <= 500
    error_message = "synthetic_account_count must be between 0 and 500."
  }
}

variable "tracked_organization" {
  description = <<-EOT
    Configure auto-discovery via AWS Organizations. When enabled, the stats
    Lambda calls organizations:ListAccounts at runtime, filters by OU/regions,
    and treats each result like a tracked_accounts entry. The reader IAM role
    is pushed to every account in the org via CloudFormation StackSets — no
    per-account terraform apply needed.

    Requires the central stack to run in either:
      - the Organizations management account, or
      - an account delegated for CloudFormation StackSets + Organizations read.
  EOT
  type = object({
    enabled              = bool
    organization_root_id = optional(string)
    ou_ids               = optional(list(string), [])
    regions              = optional(list(string), ["us-east-1"])
    role_name            = optional(string, "PipelineDashboardReader")
    exclude_account_ids  = optional(list(string), [])
  })
  # Off by default so a fresh clone works without an AWS Organization. To
  # enable org auto-discovery, set enabled=true and organization_root_id to
  # your org root (looks like "r-xxxx") in a *.tfvars file.
  default = {
    enabled = false
    regions = ["us-east-1"]
  }
}

variable "cors_allow_origin" {
  description = <<-EOT
    Single CORS allow-origin value advertised by both API Gateway and the
    Lambda response headers. Defaults to "http://localhost:5173" because the
    dashboard is local-only (see project conventions). Override in a
    gitignored *.tfvars file if you serve the dashboard from another origin.
  EOT
  type        = string
  default     = "http://localhost:5173"
}
