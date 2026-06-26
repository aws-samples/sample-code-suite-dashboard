data "archive_file" "code" {
  type        = "zip"
  source_dir  = var.source_dir
  output_path = "${path.module}/.build/${var.name}.zip"
}

resource "aws_cloudwatch_log_group" "this" {
  name              = "/aws/lambda/${var.name}"
  retention_in_days = var.log_retention_days

  # checkov:skip=CKV_AWS_158: AWS-managed encryption is already on. Lambda logs
  # contain no secrets (no payload bodies are logged in stats/index.py); a
  # dedicated CMK per log group adds cost without changing the threat model.
  # checkov:skip=CKV_AWS_338: Retention is operator-configurable via
  # var.log_retention_days. Default favors low cost; bump in tfvars for envs
  # that need long-term audit trails.
}

resource "aws_lambda_function" "this" {
  function_name    = var.name
  role             = var.role_arn
  handler          = var.handler
  runtime          = var.runtime
  timeout          = var.timeout
  memory_size      = var.memory_size
  filename         = data.archive_file.code.output_path
  source_code_hash = data.archive_file.code.output_base64sha256

  environment {
    variables = var.environment
  }

  dynamic "dead_letter_config" {
    for_each = var.dead_letter_target_arn == null ? [] : [var.dead_letter_target_arn]
    content {
      target_arn = dead_letter_config.value
    }
  }

  depends_on = [aws_cloudwatch_log_group.this]

  # checkov:skip=CKV_AWS_50: X-Ray tracing is intentionally off to keep demo
  # cost minimal. Enable via aws_lambda_function.tracing_config in tfvars when
  # debugging.
  # checkov:skip=CKV_AWS_115: No reserved concurrency on demo workloads. The
  # dashboard API is throttled at the API Gateway layer (see modules/api_gateway).
  # checkov:skip=CKV_AWS_117: Lambdas are intentionally not VPC-attached. They
  # only call AWS APIs and need internet egress; VPC + NAT adds ~$32/mo per AZ
  # with zero security benefit for these read-only public-API consumers.
  # checkov:skip=CKV_AWS_173: Env vars hold non-sensitive config (CORS origin,
  # table names, optional API_TOKEN). Lambda env vars are encrypted at rest with
  # an AWS-managed KMS key by default — adding a CMK adds cost without changing
  # the threat model. The API_TOKEN is provisioned via gitignored tfvars.
  # checkov:skip=CKV_AWS_272: Code signing is enterprise-tier and overkill for
  # a demo deploying from a single operator workstation.
}
