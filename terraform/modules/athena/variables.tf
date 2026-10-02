variable "name" {
  description = "Workgroup name."
  type        = string
}

variable "description" {
  description = "Workgroup description."
  type        = string
  default     = ""
}

variable "results_output_location" {
  description = "S3 location for query results (e.g. s3://bucket/prefix/)."
  type        = string
}
