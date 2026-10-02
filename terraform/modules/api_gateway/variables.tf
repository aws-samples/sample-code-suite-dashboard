variable "name" {
  description = "HTTP API name."
  type        = string
}

variable "lambda_function_name" {
  description = "Name of the integration target Lambda."
  type        = string
}

variable "lambda_invoke_arn" {
  description = "Invoke ARN of the integration target Lambda."
  type        = string
}

variable "routes" {
  description = "List of route keys to register (e.g. 'GET /stats')."
  type        = list(string)
}

variable "authorization_type" {
  description = <<-EOT
    HTTP API route authorization. Defaults to AWS_IAM — every caller must
    sign requests with SigV4 and have `execute-api:Invoke` on the route ARN.
    Use NONE only for endpoints that are intentionally public (none in this
    project).
  EOT
  type        = string
  default     = "AWS_IAM"
  validation {
    condition     = contains(["NONE", "AWS_IAM", "JWT", "CUSTOM"], var.authorization_type)
    error_message = "authorization_type must be NONE, AWS_IAM, JWT, or CUSTOM."
  }
}

variable "cors_allow_origins" {
  description = <<-EOT
    CORS allowed origins. Direct browser calls aren't expected (the dashboard
    proxies through the local Vite dev server which signs with SigV4), but
    we leave this configurable in case someone tests the API directly.
  EOT
  type        = list(string)
  default     = ["http://localhost:5173"]
}

variable "cors_allow_methods" {
  description = "CORS allowed methods."
  type        = list(string)
  default     = ["GET", "OPTIONS"]
}

variable "cors_allow_headers" {
  description = <<-EOT
    CORS allowed headers. Includes the SigV4 set so a SigV4-aware browser
    client could call the API directly during debugging.
  EOT
  type        = list(string)
  default = [
    "Content-Type",
    "Authorization",
    "X-Amz-Date",
    "X-Amz-Security-Token",
    "X-Amz-Content-Sha256",
  ]
}

variable "throttle_burst_limit" {
  description = "Default route throttle burst limit. Protects backing Lambda from spikes."
  type        = number
  default     = 20
}

variable "throttle_rate_limit" {
  description = "Default route throttle steady-state rate (RPS). Protects backing Lambda from sustained load."
  type        = number
  default     = 10
}

variable "access_log_retention_days" {
  description = "CloudWatch retention (days) for the API Gateway access log group."
  type        = number
  default     = 14
}
