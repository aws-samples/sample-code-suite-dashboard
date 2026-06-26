# ============================================================
# AWS Organizations integration
# ------------------------------------------------------------
# When tracked_organization.enabled is true, this file:
#   1. Pushes the cross-account reader IAM role to every account in the
#      configured OUs via a CloudFormation StackSet (service-managed,
#      auto-deployed). New accounts onboarded into those OUs auto-receive
#      the role within minutes.
#   2. Grants the central stats Lambda permission to call
#      organizations:ListAccounts so it can auto-discover what's there
#      at runtime.
#
# The IAM role pushed to each account costs nothing — it's read-only and
# gets assumed only when the dashboard is fetching data.
# ============================================================

locals {
  org_enabled = var.tracked_organization.enabled

  # Default to the entire organization if no OUs are specified — i.e. the
  # StackSet target is the org root.
  stackset_org_targets = local.org_enabled ? (
    length(var.tracked_organization.ou_ids) > 0
    ? var.tracked_organization.ou_ids
    : [var.tracked_organization.organization_root_id]
  ) : []
}

resource "aws_cloudformation_stack_set" "reader_role" {
  count = local.org_enabled ? 1 : 0

  name             = "${var.project_name}-reader-role"
  description      = "Read-only IAM role assumed by the pipeline-dashboard stats Lambda. Deployed to every account in the org."
  permission_model = "SERVICE_MANAGED"
  capabilities     = ["CAPABILITY_NAMED_IAM"]

  auto_deployment {
    enabled                          = true
    retain_stacks_on_account_removal = false
  }

  parameters = {
    CentralLambdaRoleArn = aws_iam_role.stats_lambda.arn
    RoleName             = var.tracked_organization.role_name
  }

  template_body = file("${path.module}/reader-role-stackset.yaml")

  lifecycle {
    ignore_changes = [administration_role_arn]
  }
}

resource "aws_cloudformation_stack_set_instance" "reader_role" {
  count = local.org_enabled ? 1 : 0

  stack_set_name            = aws_cloudformation_stack_set.reader_role[0].name
  stack_set_instance_region = local.region

  deployment_targets {
    organizational_unit_ids = local.stackset_org_targets
    account_filter_type     = length(var.tracked_organization.exclude_account_ids) > 0 ? "DIFFERENCE" : "NONE"
    accounts                = length(var.tracked_organization.exclude_account_ids) > 0 ? var.tracked_organization.exclude_account_ids : null
  }

  operation_preferences {
    # Surface partial failures instead of silently tolerating an entire org-wide
    # outage. 25% lets a few stragglers through (cold accounts, brand-new ones)
    # without blocking the whole rollout.
    failure_tolerance_percentage = 25
    max_concurrent_percentage    = 50
    region_concurrency_type      = "PARALLEL"
  }
}

