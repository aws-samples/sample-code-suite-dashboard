# -----------------------------------------------------------------------------
# One CodeCommit repo + one CodeBuild project + one CodePipeline per sample.
# The shared modules in ../modules/ are reused so this stack stays small.
# -----------------------------------------------------------------------------

resource "aws_codecommit_repository" "this" {
  for_each = var.samples

  repository_name = "${var.name_prefix}-${each.key}"
  description     = each.value.description

  # checkov:skip=CKV2_AWS_37: Sample repos are auto-seeded demo content owned
  # by the same operator who runs `make deploy-sample-pipelines`. Approval
  # rules would block the seed commit and serve no review purpose.
}

module "build" {
  for_each = var.samples
  source   = "../modules/codebuild"

  name             = "${var.name_prefix}-${each.key}-build"
  service_role_arn = aws_iam_role.codebuild.arn
  # The repo's buildspec.yml drives the build steps.
}

module "pipeline" {
  for_each = var.samples
  source   = "../modules/codepipeline"

  name               = "${var.name_prefix}-${each.key}-pipeline"
  role_arn           = aws_iam_role.codepipeline.arn
  artifact_bucket    = aws_s3_bucket.artifacts.id
  source_repo_name   = aws_codecommit_repository.this[each.key].repository_name
  source_branch      = "main"
  build_project_name = module.build[each.key].name

  depends_on = [
    aws_iam_role_policy.codepipeline,
    aws_iam_role_policy.codebuild,
    null_resource.seed,
  ]
}

# Tag each pipeline with the AlertSeverity tag that the future
# pipeline-failure-alerts router will read. The codepipeline module
# doesn't expose tags as a variable, so we tag out-of-band via the AWS CLI.
resource "null_resource" "pipeline_tags" {
  for_each = var.samples

  triggers = {
    pipeline_arn = module.pipeline[each.key].arn
    severity     = each.value.severity_tag
  }

  provisioner "local-exec" {
    command = <<-EOT
      aws codepipeline tag-resource \
        --region ${var.aws_region} \
        --resource-arn ${module.pipeline[each.key].arn} \
        --tags key=AlertSeverity,value=${each.value.severity_tag} \
               key=Sample,value=${each.key}
    EOT
  }
}
