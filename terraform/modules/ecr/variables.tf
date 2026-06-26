variable "name" {
  description = "ECR repository name."
  type        = string
}

variable "scan_on_push" {
  description = "Whether to scan images on push."
  type        = bool
  default     = true
}

variable "keep_last_n_images" {
  description = "Lifecycle policy: keep this many images, expire the rest."
  type        = number
  default     = 10
}

variable "force_delete" {
  description = "Whether Terraform can delete the repo even if it contains images."
  type        = bool
  default     = false
}
