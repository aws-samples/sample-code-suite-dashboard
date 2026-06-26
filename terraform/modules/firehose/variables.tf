variable "name" {
  description = "Delivery stream name."
  type        = string
}

variable "destination_bucket_arn" {
  description = "S3 destination bucket ARN."
  type        = string
}

variable "role_arn" {
  description = "IAM role ARN with PutObject access to the destination."
  type        = string
}

variable "prefix" {
  description = "S3 key prefix for delivered records."
  type        = string
}

variable "error_output_prefix" {
  description = "S3 key prefix for failed records."
  type        = string
}

variable "buffering_interval" {
  description = "Buffering interval in seconds."
  type        = number
  default     = 60
}

variable "buffering_size" {
  description = "Buffering size in MiB."
  type        = number
  default     = 1
}
