locals {
  log_group_name = coalesce(var.log_group_name, "/aws/codebuild/${var.name}")
}

resource "aws_cloudwatch_log_group" "build" {
  name              = local.log_group_name
  retention_in_days = var.log_retention_days

  # checkov:skip=CKV_AWS_158: AWS-managed encryption is already on. Customer
  # KMS keys add ~$1/mo per key for no marginal benefit on demo build logs.
  # checkov:skip=CKV_AWS_338: Retention is configurable via var.log_retention_days;
  # default favors low cost on demo workloads. Bump in tfvars for long-lived envs.
}

resource "aws_codebuild_project" "this" {
  name         = var.name
  service_role = var.service_role_arn

  artifacts {
    type = var.artifacts_type
  }

  environment {
    type            = "LINUX_CONTAINER"
    image           = var.environment_image
    compute_type    = var.environment_compute_type
    privileged_mode = var.privileged_mode

    dynamic "environment_variable" {
      for_each = var.environment_variables
      content {
        name  = environment_variable.key
        value = environment_variable.value
      }
    }
  }

  source {
    type      = var.source_type
    location  = var.source_location
    buildspec = var.buildspec
  }

  logs_config {
    cloudwatch_logs {
      status     = "ENABLED"
      group_name = aws_cloudwatch_log_group.build.name
    }
  }

  # checkov:skip=CKV_AWS_147: Build artifacts go through the shared artifact
  # bucket which already has SSE-S3. CodeBuild CMK encryption would require
  # provisioning a KMS key per project + grants for the service role on a
  # demo workload that builds public sample apps. Revisit if builds start
  # handling secrets.
}
