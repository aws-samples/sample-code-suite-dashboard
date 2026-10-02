# ============================================================
# Chat backend
# ------------------------------------------------------------
# Async request-response pattern for the dashboard's DevOps-Agent-powered
# chat feature. DevOps Agent send_message returns a streaming EventStream
# that can take longer than API Gateway's 30s hard timeout, so:
#
#   POST /chat  (handled by stats Lambda)
#     ↓ writes {chatId, status=processing} to DynamoDB
#     ↓ invokes chat-worker Lambda asynchronously
#     ↓ returns {chatId} immediately
#
#   Chat worker Lambda
#     ↓ calls devops-agent:CreateChat, then send_message
#     ↓ consumes the event stream, accumulates text
#     ↓ writes {status=succeeded, answer} back to DynamoDB
#
#   GET /chat/{chatId}  (handled by stats Lambda)
#     ↓ reads DynamoDB and returns current state
#
# The frontend polls GET /chat/{chatId} every ~2s until status is terminal.
# ============================================================

resource "aws_dynamodb_table" "chat" {
  name         = "${var.project_name}-chat"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "chatId"

  attribute {
    name = "chatId"
    type = "S"
  }

  # Auto-delete chat records after 24 hours so the table doesn't grow.
  ttl {
    enabled        = true
    attribute_name = "expiresAt"
  }

  point_in_time_recovery {
    enabled = false
  }

  server_side_encryption {
    enabled = true
  }

  # checkov:skip=CKV_AWS_28: PITR intentionally off — chat state is
  # ephemeral (24h TTL) and cheap to reconstruct by re-asking.
}

# ---------- Chat worker Lambda ----------

resource "aws_iam_role" "chat_worker" {
  name               = "${var.project_name}-chat-worker-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}

data "aws_iam_policy_document" "chat_worker" {
  statement {
    sid = "DevOpsAgentChat"
    # Note: boto3 client name is `devops-agent`, but IAM action + resource
    # ARN prefix are both `aidevops`. Confirmed via CloudTrail
    # AccessDeniedException on the first apply.
    actions   = ["aidevops:CreateChat", "aidevops:SendMessage"]
    resources = ["arn:aws:aidevops:${local.region}:${local.account_id}:agentspace/${awscc_devopsagent_agent_space.this.id}"]
  }

  statement {
    sid     = "ChatTableWrite"
    actions = ["dynamodb:UpdateItem", "dynamodb:GetItem", "dynamodb:PutItem"]
    resources = [
      aws_dynamodb_table.chat.arn,
    ]
  }

  statement {
    sid       = "CloudWatchLogs"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["arn:aws:logs:${local.region}:${local.account_id}:log-group:/aws/lambda/${var.project_name}-chat-worker:*"]
  }
}

resource "aws_iam_role_policy" "chat_worker" {
  name   = "${var.project_name}-chat-worker-policy"
  role   = aws_iam_role.chat_worker.id
  policy = data.aws_iam_policy_document.chat_worker.json
}

module "chat_worker_lambda" {
  source = "../modules/lambda"

  name        = "${var.project_name}-chat-worker"
  role_arn    = aws_iam_role.chat_worker.arn
  source_dir  = "${path.module}/lambda/chat_worker"
  timeout     = 300 # 5 min — DevOps Agent investigations can take a while
  memory_size = 512
  environment = {
    AGENT_SPACE_ID  = awscc_devopsagent_agent_space.this.id
    CHAT_TABLE_NAME = aws_dynamodb_table.chat.name
    REGION          = local.region
  }
}
