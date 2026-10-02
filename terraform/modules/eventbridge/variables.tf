variable "name" {
  description = "EventBridge rule name."
  type        = string
}

variable "description" {
  description = "Rule description."
  type        = string
  default     = ""
}

variable "event_pattern" {
  description = "JSON event pattern (use jsonencode in caller)."
  type        = string
}

variable "targets" {
  description = "List of targets for the rule."
  type = list(object({
    id         = string
    arn        = string
    role_arn   = optional(string)
    input      = optional(string)
    input_path = optional(string)
    input_transformer = optional(object({
      input_paths    = map(string)
      input_template = string
    }))
  }))
}
