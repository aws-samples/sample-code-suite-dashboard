resource "aws_codepipeline" "this" {
  name     = var.name
  role_arn = var.role_arn

  artifact_store {
    type     = "S3"
    location = var.artifact_bucket
  }

  # checkov:skip=CKV_AWS_219: Artifact bucket already enforces SSE-S3 (see
  # sample-pipelines/iam.tf::aws_s3_bucket_server_side_encryption_configuration).
  # A dedicated CMK for the pipeline artifact store would add a KMS key per
  # stack with no measurable risk reduction for demo builds.

  stage {
    name = "Source"
    action {
      name             = "Source"
      category         = "Source"
      owner            = "AWS"
      provider         = "CodeCommit"
      version          = "1"
      output_artifacts = ["SourceOutput"]
      configuration = {
        RepositoryName       = var.source_repo_name
        BranchName           = var.source_branch
        PollForSourceChanges = "false"
      }
    }
  }

  stage {
    name = "Build"
    action {
      name             = "Build"
      category         = "Build"
      owner            = "AWS"
      provider         = "CodeBuild"
      version          = "1"
      input_artifacts  = ["SourceOutput"]
      output_artifacts = ["BuildOutput"]
      configuration = {
        ProjectName = var.build_project_name
      }
    }
  }
}
