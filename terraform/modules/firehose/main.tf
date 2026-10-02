resource "aws_kinesis_firehose_delivery_stream" "this" {
  name        = var.name
  destination = "extended_s3"

  extended_s3_configuration {
    role_arn            = var.role_arn
    bucket_arn          = var.destination_bucket_arn
    prefix              = var.prefix
    error_output_prefix = var.error_output_prefix
    buffering_interval  = var.buffering_interval
    buffering_size      = var.buffering_size
  }

  # checkov:skip=CKV_AWS_240: Data lands in an S3 bucket that already has
  # SSE-S3 on by default (see modules/s3). Firehose server-side encryption
  # is unnecessary for pipeline event metadata.
  # checkov:skip=CKV_AWS_241: Same reason as CKV_AWS_240 — destination
  # bucket encryption is the security boundary. A dedicated CMK adds cost
  # without changing the threat model for demo telemetry.
}
