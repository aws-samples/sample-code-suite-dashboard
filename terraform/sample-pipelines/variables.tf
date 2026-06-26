variable "aws_region" {
  description = "AWS region to deploy the sample pipelines into. Should match the dashboard backend so the UI picks them up."
  type        = string
  default     = "us-east-1"
}

variable "name_prefix" {
  description = "Prefix applied to every resource name so the sample stack is easy to identify and clean up."
  type        = string
  default     = "sample"
  validation {
    condition     = can(regex("^[a-z0-9-]{1,16}$", var.name_prefix))
    error_message = "name_prefix must be 1-16 chars, lowercase letters/numbers/hyphens only."
  }
}

variable "samples" {
  description = <<-EOT
    Map of sample pipelines to provision. Each entry creates one CodeCommit repo,
    one CodeBuild project, and one CodePipeline. The key becomes part of every
    resource name and is what shows up in the dashboard.
  EOT
  type = map(object({
    source_dir   = string # path under sample-apps/, e.g. "python-api"
    description  = string
    severity_tag = string # "high" | "medium" | "low" — drives the future alerts feature
  }))
  default = {
    python-api = {
      source_dir   = "python-api"
      description  = "Flask service with pytest, demonstrates a Python build."
      severity_tag = "high"
    }
    node-api = {
      source_dir   = "node-api"
      description  = "Express service with Jest, demonstrates a Node build."
      severity_tag = "medium"
    }
    static-site = {
      source_dir   = "static-site"
      description  = "Tiny static site, demonstrates a content-only build."
      severity_tag = "low"
    }
  }
}
