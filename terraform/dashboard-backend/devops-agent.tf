# ============================================================
# AWS DevOps Agent integration
# ------------------------------------------------------------
# Provisions the AgentSpace + IAM the chat feature calls into. The chat
# worker Lambda (see chat.tf) calls devops-agent:CreateChat +
# devops-agent:SendMessage against this AgentSpace when the user asks a
# question about a pipeline.
#
# IAM shape mirrors aws-samples/sample-aws-devops-agent-terraform: two
# service-linked-ish roles trusted by aidevops.amazonaws.com, one for
# the AgentSpace itself (broad read via AIDevOpsAgentAccessPolicy) and
# one for the Operator App (AIDevOpsOperatorAppAccessPolicy).
# ============================================================

resource "random_id" "devops_agent_suffix" {
  byte_length = 4
}

# ---------- AgentSpace role (broad monitoring access) ----------

data "aws_iam_policy_document" "devops_agentspace_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["aidevops.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = ["arn:aws:aidevops:${local.region}:${local.account_id}:agentspace/*"]
    }
  }
}

resource "aws_iam_role" "devops_agentspace" {
  name               = "${var.project_name}-devops-agentspace-${random_id.devops_agent_suffix.hex}"
  description        = "Assumed by AWS DevOps Agent to monitor CodePipeline + CodeBuild on behalf of the ${var.project_name} AgentSpace."
  assume_role_policy = data.aws_iam_policy_document.devops_agentspace_trust.json
}

resource "aws_iam_role_policy_attachment" "devops_agentspace_access" {
  role       = aws_iam_role.devops_agentspace.name
  policy_arn = "arn:aws:iam::aws:policy/AIDevOpsAgentAccessPolicy"
}

# Resource Explorer service-linked role — created by the agent on first use.
data "aws_iam_policy_document" "devops_agentspace_slr" {
  statement {
    sid     = "AllowCreateServiceLinkedRoles"
    effect  = "Allow"
    actions = ["iam:CreateServiceLinkedRole"]
    resources = [
      "arn:aws:iam::${local.account_id}:role/aws-service-role/resource-explorer-2.amazonaws.com/AWSServiceRoleForResourceExplorer",
    ]
  }
}

resource "aws_iam_role_policy" "devops_agentspace_slr" {
  name   = "AllowCreateServiceLinkedRoles"
  role   = aws_iam_role.devops_agentspace.id
  policy = data.aws_iam_policy_document.devops_agentspace_slr.json
}

# ---------- Operator App role ----------

data "aws_iam_policy_document" "devops_operator_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole", "sts:TagSession"]
    principals {
      type        = "Service"
      identifiers = ["aidevops.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = ["arn:aws:aidevops:${local.region}:${local.account_id}:agentspace/*"]
    }
  }
}

resource "aws_iam_role" "devops_operator" {
  name               = "${var.project_name}-devops-operator-${random_id.devops_agent_suffix.hex}"
  description        = "Operator App role for the ${var.project_name} DevOps AgentSpace. Grants human-user access to the chat interface."
  assume_role_policy = data.aws_iam_policy_document.devops_operator_trust.json
}

resource "aws_iam_role_policy_attachment" "devops_operator_access" {
  role       = aws_iam_role.devops_operator.name
  policy_arn = "arn:aws:iam::aws:policy/AIDevOpsOperatorAppAccessPolicy"
}

# ---------- IAM propagation buffer ----------
# The AgentSpace resource validates trust policies at create time; wait for
# IAM eventual consistency to avoid intermittent failures on first apply.
resource "time_sleep" "wait_for_devops_agent_iam" {
  depends_on = [
    aws_iam_role_policy_attachment.devops_agentspace_access,
    aws_iam_role_policy.devops_agentspace_slr,
    aws_iam_role_policy_attachment.devops_operator_access,
  ]
  create_duration = "30s"
}

# ---------- AgentSpace + primary account association ----------

resource "awscc_devopsagent_agent_space" "this" {
  name        = "${var.project_name}-agent-space"
  description = "AgentSpace for the ${var.project_name} dashboard chat. Investigates CodePipeline + CodeBuild activity."
  operator_app = {
    iam = {
      operator_app_role_arn = aws_iam_role.devops_operator.arn
    }
  }

  depends_on = [time_sleep.wait_for_devops_agent_iam]
}

resource "awscc_devopsagent_association" "primary_aws_account" {
  agent_space_id = awscc_devopsagent_agent_space.this.id
  service_id     = "aws"
  configuration = {
    aws = {
      assumable_role_arn = aws_iam_role.devops_agentspace.arn
      account_id         = local.account_id
      account_type       = "monitor"
      resources          = []
    }
  }

  depends_on = [awscc_devopsagent_agent_space.this]
}
