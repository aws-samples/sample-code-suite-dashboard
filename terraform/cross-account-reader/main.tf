# Cross-account reader role: deployed into a TARGET account so the central
# dashboard Lambda can list pipelines + builds there. Read-only by design.
data "aws_caller_identity" "current" {}

# Trust policy: only the central stats Lambda role can assume this.
data "aws_iam_policy_document" "trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "AWS"
      identifiers = [var.central_lambda_role_arn]
    }
  }
}

resource "aws_iam_role" "this" {
  name               = var.role_name
  description        = "Read-only role assumed by the central pipeline-dashboard stats Lambda."
  assume_role_policy = data.aws_iam_policy_document.trust.json
}

# Resource ARN scoping notes:
#   - codepipeline:ListPipelines and codebuild:ListBuilds do NOT support
#     resource-level permissions, so they MUST use "*".
#   - All other reads support resource ARNs, so we scope them to this account.
data "aws_iam_policy_document" "read" {
  statement {
    sid = "CodePipelineList"
    # checkov:skip=CKV_AWS_107: ListPipelines has no resource-level support per AWS docs.
    actions   = ["codepipeline:ListPipelines"]
    resources = ["*"]
  }
  statement {
    sid = "CodePipelineRead"
    actions = [
      "codepipeline:GetPipeline",
      "codepipeline:GetPipelineState",
      "codepipeline:ListPipelineExecutions",
      "codepipeline:GetPipelineExecution",
      "codepipeline:ListActionExecutions",
    ]
    resources = [
      "arn:aws:codepipeline:*:${data.aws_caller_identity.current.account_id}:*",
    ]
  }
  statement {
    sid = "CodeBuildList"
    # checkov:skip=CKV_AWS_107: ListBuilds has no resource-level support per AWS docs.
    actions   = ["codebuild:ListBuilds"]
    resources = ["*"]
  }
  statement {
    sid       = "CodeBuildRead"
    actions   = ["codebuild:BatchGetBuilds"]
    resources = ["arn:aws:codebuild:*:${data.aws_caller_identity.current.account_id}:project/*"]
  }
}

resource "aws_iam_role_policy" "read" {
  name   = "${var.role_name}-read"
  role   = aws_iam_role.this.id
  policy = data.aws_iam_policy_document.read.json
}
