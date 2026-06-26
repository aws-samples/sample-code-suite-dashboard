resource "aws_s3_bucket" "this" {
  bucket        = var.bucket_name
  force_destroy = var.force_destroy
  tags          = var.tags

  # checkov:skip=CKV_AWS_18: Access logging is off to avoid a second log bucket
  # for a demo workload. The bucket is private (public access block below) and
  # API access is via dedicated IAM roles that already write CloudTrail events.
  # checkov:skip=CKV_AWS_144: No cross-region replication. The data is rebuildable
  # demo telemetry; replication would double storage cost for no recovery benefit.
  # checkov:skip=CKV_AWS_145: SSE-S3 (AES256) is already enabled below. A KMS CMK
  # adds ~$1/mo per bucket plus per-request KMS charges with no marginal benefit
  # for non-sensitive demo data.
  # checkov:skip=CKV2_AWS_61: No lifecycle config — demo data volume is small and
  # is wiped via `terraform destroy`. Add a rule in tfvars if the bucket grows.
  # checkov:skip=CKV2_AWS_62: No event notifications configured because nothing
  # downstream subscribes to bucket events in this stack.
}

resource "aws_s3_bucket_public_access_block" "this" {
  bucket                  = aws_s3_bucket.this.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "this" {
  bucket = aws_s3_bucket.this.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_versioning" "this" {
  count  = var.versioning_enabled ? 1 : 0
  bucket = aws_s3_bucket.this.id
  versioning_configuration {
    status = "Enabled"
  }
}

# Deny non-TLS access. Standard hardening; required by checkov CKV_AWS_18 / CKV2_AWS_6.
data "aws_iam_policy_document" "deny_insecure_transport" {
  statement {
    sid     = "DenyInsecureTransport"
    effect  = "Deny"
    actions = ["s3:*"]
    resources = [
      aws_s3_bucket.this.arn,
      "${aws_s3_bucket.this.arn}/*",
    ]
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "this" {
  bucket = aws_s3_bucket.this.id
  policy = data.aws_iam_policy_document.deny_insecure_transport.json

  # Public-access block must exist first or the policy upload fails on a
  # fresh bucket. Terraform doesn't always order these correctly without
  # this hint.
  depends_on = [aws_s3_bucket_public_access_block.this]
}
