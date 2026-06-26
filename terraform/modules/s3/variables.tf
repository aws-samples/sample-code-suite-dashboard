variable "bucket_name" {
  description = "Name of the S3 bucket."
  type        = string
}

variable "versioning_enabled" {
  description = "Whether to enable versioning on the bucket."
  type        = bool
  default     = false
}

variable "force_destroy" {
  description = "Allow Terraform to destroy a non-empty bucket."
  type        = bool
  default     = false
}

variable "tags" {
  description = "Tags applied to the bucket."
  type        = map(string)
  default     = {}
}
