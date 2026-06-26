variable "name" {
  description = "Lambda function name."
  type        = string
}

variable "role_arn" {
  description = "IAM role ARN for the function."
  type        = string
}

variable "source_dir" {
  description = "Local directory whose contents are zipped and uploaded as the function code."
  type        = string
}

variable "handler" {
  description = "Lambda handler entrypoint."
  type        = string
  default     = "index.handler"
}

variable "runtime" {
  description = "Lambda runtime."
  type        = string
  default     = "python3.12"
}

variable "timeout" {
  description = "Function timeout in seconds."
  type        = number
  default     = 30
}

variable "memory_size" {
  description = "Function memory in MB."
  type        = number
  default     = 256
}

variable "environment" {
  description = "Environment variables passed to the function."
  type        = map(string)
  default     = {}
}

variable "log_retention_days" {
  description = "Retention for the function's log group."
  type        = number
  default     = 14
}

variable "dead_letter_target_arn" {
  description = <<-EOT
    Optional SQS queue or SNS topic ARN to receive async-invocation failures.
    When set, the Lambda gets a DLQ; the role must also have permission to
    publish to the target.
  EOT
  type        = string
  default     = null
}
