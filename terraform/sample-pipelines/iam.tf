data "aws_caller_identity" "current" {}

# -----------------------------------------------------------------------------
# Shared artifact bucket — one bucket holds artifacts for every sample pipeline.
# -----------------------------------------------------------------------------
resource "aws_s3_bucket" "artifacts" {
  bucket        = "${var.name_prefix}-pipelines-artifacts-${data.aws_caller_identity.current.account_id}"
  force_destroy = true

  # checkov:skip=CKV_AWS_18: Access logging is off — demo workload, single
  # operator account, no compliance audit need.
  # checkov:skip=CKV_AWS_144: No cross-region replication — artifacts are
  # rebuildable from CodeCommit + buildspec; replication doubles cost.
  # checkov:skip=CKV_AWS_145: SSE-S3 (AES256) is already enabled below. CMK
  # encryption adds cost with no marginal benefit for demo build artifacts.
  # checkov:skip=CKV2_AWS_61: No lifecycle — `terraform destroy` cleans up.
  # checkov:skip=CKV2_AWS_62: No event notifications — no downstream subscribers.
}

resource "aws_s3_bucket_public_access_block" "artifacts" {
  bucket                  = aws_s3_bucket.artifacts.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_versioning" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id
  versioning_configuration {
    status = "Enabled"
  }
}

# Deny non-TLS access to the artifact bucket. Same hardening as the shared
# S3 module — checkov CKV_AWS_18 / CKV2_AWS_6.
data "aws_iam_policy_document" "artifacts_deny_insecure_transport" {
  statement {
    sid     = "DenyInsecureTransport"
    effect  = "Deny"
    actions = ["s3:*"]
    resources = [
      aws_s3_bucket.artifacts.arn,
      "${aws_s3_bucket.artifacts.arn}/*",
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

resource "aws_s3_bucket_policy" "artifacts" {
  bucket     = aws_s3_bucket.artifacts.id
  policy     = data.aws_iam_policy_document.artifacts_deny_insecure_transport.json
  depends_on = [aws_s3_bucket_public_access_block.artifacts]
}

# -----------------------------------------------------------------------------
# CodePipeline service role — one role shared across all sample pipelines.
# Scoped to this stack's repos, build projects, and artifact bucket.
# -----------------------------------------------------------------------------
data "aws_iam_policy_document" "codepipeline_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["codepipeline.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "codepipeline" {
  name               = "${var.name_prefix}-pipelines-codepipeline-role"
  assume_role_policy = data.aws_iam_policy_document.codepipeline_trust.json
}

data "aws_iam_policy_document" "codepipeline" {
  statement {
    sid    = "ArtifactBucket"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:GetObjectVersion",
      "s3:PutObject",
      "s3:GetBucketVersioning",
    ]
    resources = [
      aws_s3_bucket.artifacts.arn,
      "${aws_s3_bucket.artifacts.arn}/*",
    ]
  }
  statement {
    sid    = "CodeCommitSource"
    effect = "Allow"
    actions = [
      "codecommit:GetBranch",
      "codecommit:GetCommit",
      "codecommit:UploadArchive",
      "codecommit:GetUploadArchiveStatus",
      "codecommit:CancelUploadArchive",
    ]
    resources = [for k, _ in var.samples :
      "arn:aws:codecommit:${var.aws_region}:${data.aws_caller_identity.current.account_id}:${var.name_prefix}-${k}"
    ]
  }
  statement {
    sid    = "CodeBuildInvoke"
    effect = "Allow"
    actions = [
      "codebuild:StartBuild",
      "codebuild:StopBuild",
      "codebuild:BatchGetBuilds",
    ]
    resources = [for k, _ in var.samples :
      "arn:aws:codebuild:${var.aws_region}:${data.aws_caller_identity.current.account_id}:project/${var.name_prefix}-${k}-build"
    ]
  }
}

resource "aws_iam_role_policy" "codepipeline" {
  name   = "${var.name_prefix}-pipelines-codepipeline-policy"
  role   = aws_iam_role.codepipeline.id
  policy = data.aws_iam_policy_document.codepipeline.json
}

# -----------------------------------------------------------------------------
# CodeBuild service role — shared across all sample build projects.
# -----------------------------------------------------------------------------
data "aws_iam_policy_document" "codebuild_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["codebuild.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "codebuild" {
  name               = "${var.name_prefix}-pipelines-codebuild-role"
  assume_role_policy = data.aws_iam_policy_document.codebuild_trust.json
}

data "aws_iam_policy_document" "codebuild" {
  statement {
    sid    = "Logs"
    effect = "Allow"
    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]
    resources = ["arn:aws:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/codebuild/${var.name_prefix}-*"]
  }
  statement {
    sid    = "ArtifactBucket"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:GetObjectVersion",
      "s3:PutObject",
      "s3:GetBucketVersioning",
    ]
    resources = [
      aws_s3_bucket.artifacts.arn,
      "${aws_s3_bucket.artifacts.arn}/*",
    ]
  }
}

resource "aws_iam_role_policy" "codebuild" {
  name   = "${var.name_prefix}-pipelines-codebuild-policy"
  role   = aws_iam_role.codebuild.id
  policy = data.aws_iam_policy_document.codebuild.json
}
