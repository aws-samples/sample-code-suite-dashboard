resource "aws_athena_workgroup" "this" {
  name        = var.name
  description = var.description
  state       = "ENABLED"

  configuration {
    enforce_workgroup_configuration = true

    result_configuration {
      output_location = var.results_output_location
    }
  }

  force_destroy = true

  # checkov:skip=CKV_AWS_159: Query results land in an S3 bucket that already
  # has SSE-S3 (AES256) on by default (see modules/s3). Customer KMS keys for
  # Athena workgroup encryption add cost and IAM complexity on a demo workload
  # that processes no sensitive data.
}
