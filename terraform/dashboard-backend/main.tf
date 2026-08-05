data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

# Resolve the org ID at apply time so the cross-account AssumeRole condition
# scopes correctly without hardcoding the value in source. Only queried when
# Organizations integration is enabled.
data "aws_organizations_organization" "this" {
  count = var.tracked_organization.enabled ? 1 : 0
}

locals {
  account_id = data.aws_caller_identity.current.account_id
  region     = data.aws_region.current.region
  org_id     = var.tracked_organization.enabled ? data.aws_organizations_organization.this[0].id : ""

  synthetic_aliases = [
    "prod", "stage", "dev", "qa", "preview", "sandbox", "data", "platform",
    "ml", "ops", "audit", "shared-services", "tools", "security", "logging",
  ]
  synthetic_regions = [
    "us-east-1", "us-west-2", "eu-west-1", "eu-central-1",
    "ap-southeast-2", "ap-northeast-1",
  ]
  # Synthetic accounts are generated *inside the Lambda* from
  # SYNTHETIC_ACCOUNT_COUNT to keep the env-var payload small (Lambda has a
  # ~4 KB limit on environment configuration).
}

# ============================================================
# S3 data lake
# ============================================================
module "data_lake" {
  source = "../modules/s3"

  bucket_name        = "${var.project_name}-data-${local.account_id}"
  versioning_enabled = false
}

# ============================================================
# IAM: Firehose + EventBridge-to-Firehose
# ============================================================
data "aws_iam_policy_document" "firehose_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["firehose.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "firehose" {
  name               = "${var.project_name}-firehose-role"
  assume_role_policy = data.aws_iam_policy_document.firehose_assume.json
}

resource "aws_iam_role_policy" "firehose" {
  name = "${var.project_name}-firehose-policy"
  role = aws_iam_role.firehose.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "s3:PutObject", "s3:GetBucketLocation", "s3:AbortMultipartUpload",
        "s3:ListBucket", "s3:ListBucketMultipartUploads",
      ]
      Resource = [module.data_lake.arn, "${module.data_lake.arn}/*"]
    }]
  })
}

data "aws_iam_policy_document" "events_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "events_to_firehose" {
  name               = "${var.project_name}-eventbridge-firehose-role"
  assume_role_policy = data.aws_iam_policy_document.events_assume.json
}

# ============================================================
# Firehose delivery streams
# ============================================================
module "pipeline_events_stream" {
  source = "../modules/firehose"

  name                   = "${var.project_name}-pipeline-events"
  destination_bucket_arn = module.data_lake.arn
  role_arn               = aws_iam_role.firehose.arn
  prefix                 = "pipeline-events/year=!{timestamp:yyyy}/month=!{timestamp:MM}/day=!{timestamp:dd}/"
  error_output_prefix    = "errors/pipeline-events/"
}

module "build_events_stream" {
  source = "../modules/firehose"

  name                   = "${var.project_name}-build-events"
  destination_bucket_arn = module.data_lake.arn
  role_arn               = aws_iam_role.firehose.arn
  prefix                 = "build-events/year=!{timestamp:yyyy}/month=!{timestamp:MM}/day=!{timestamp:dd}/"
  error_output_prefix    = "errors/build-events/"
}

resource "aws_iam_role_policy" "events_to_firehose" {
  name = "${var.project_name}-eventbridge-firehose-policy"
  role = aws_iam_role.events_to_firehose.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["firehose:PutRecord", "firehose:PutRecordBatch"]
      Resource = [module.pipeline_events_stream.arn, module.build_events_stream.arn]
    }]
  })
}

# ============================================================
# EventBridge: capture all pipeline + build events into Firehose
# ============================================================
module "pipeline_events_rule" {
  source = "../modules/eventbridge"

  name        = "${var.project_name}-pipeline-events-rule"
  description = "Captures all CodePipeline execution state changes"

  event_pattern = jsonencode({
    source        = ["aws.codepipeline"]
    "detail-type" = ["CodePipeline Pipeline Execution State Change"]
  })

  targets = [{
    id       = "PipelineFirehoseTarget"
    arn      = module.pipeline_events_stream.arn
    role_arn = aws_iam_role.events_to_firehose.arn
  }]
}

module "build_events_rule" {
  source = "../modules/eventbridge"

  name        = "${var.project_name}-build-events-rule"
  description = "Captures all CodeBuild build state changes"

  event_pattern = jsonencode({
    source        = ["aws.codebuild"]
    "detail-type" = ["CodeBuild Build State Change"]
  })

  targets = [{
    id       = "BuildFirehoseTarget"
    arn      = module.build_events_stream.arn
    role_arn = aws_iam_role.events_to_firehose.arn
  }]
}

# ============================================================
# Glue catalog (database + 4 tables)
# ============================================================
module "glue_database" {
  source = "../modules/glue"

  create_database      = true
  database_name        = "pipeline_dashboard_db"
  database_description = "CI/CD pipeline observability data"
}

module "pipeline_executions_table" {
  source = "../modules/glue"

  create_table        = true
  table_name          = "pipeline_executions"
  table_database_name = module.glue_database.database_name
  table_location      = "s3://${module.data_lake.id}/pipeline-events/"
  table_serde_paths   = "version,id,detail-type,source,account,time,region,detail"
  table_columns = [
    { name = "version", type = "string" },
    { name = "id", type = "string" },
    { name = "detail-type", type = "string" },
    { name = "source", type = "string" },
    { name = "account", type = "string" },
    { name = "time", type = "string" },
    { name = "region", type = "string" },
    { name = "detail", type = "struct<pipeline:string,execution-id:string,state:string,version:int>" },
  ]
}

module "build_events_table" {
  source = "../modules/glue"

  create_table        = true
  table_name          = "build_events"
  table_database_name = module.glue_database.database_name
  table_location      = "s3://${module.data_lake.id}/build-events/"
  table_serde_paths   = "version,id,detail-type,source,account,time,region,detail"
  table_columns = [
    { name = "version", type = "string" },
    { name = "id", type = "string" },
    { name = "detail-type", type = "string" },
    { name = "source", type = "string" },
    { name = "account", type = "string" },
    { name = "time", type = "string" },
    { name = "region", type = "string" },
    { name = "detail", type = "struct<build-status:string,project-name:string,build-id:string,current-phase:string,additional-information:struct<build-start-time:string,build-complete-time:string,initiator:string,source-version:string>>" },
  ]
}

module "enriched_pipeline_executions_table" {
  source = "../modules/glue"

  create_table        = true
  table_name          = "enriched_pipeline_executions"
  table_database_name = module.glue_database.database_name
  table_location      = "s3://${module.data_lake.id}/enriched/pipeline-executions/"
  table_columns = [
    { name = "pipeline_name", type = "string" },
    { name = "execution_id", type = "string" },
    { name = "execution_status", type = "string" },
    { name = "trigger_type", type = "string" },
    { name = "source_revision", type = "string" },
    { name = "deployed_version", type = "string" },
    { name = "execution_start_time", type = "string" },
    { name = "execution_end_time", type = "string" },
    { name = "total_duration_seconds", type = "int" },
    { name = "is_deployment", type = "boolean" },
    { name = "stages", type = "array<struct<stage_name:string,status:string,start_time:string,end_time:string,failure_reason:string>>" },
    { name = "enriched_at", type = "string" },
  ]
}

module "enriched_build_details_table" {
  source = "../modules/glue"

  create_table        = true
  table_name          = "enriched_build_details"
  table_database_name = module.glue_database.database_name
  table_location      = "s3://${module.data_lake.id}/enriched/build-details/"
  table_columns = [
    { name = "project_name", type = "string" },
    { name = "build_id", type = "string" },
    { name = "build_status", type = "string" },
    { name = "build_duration_seconds", type = "int" },
    { name = "initiator", type = "string" },
    { name = "source_version", type = "string" },
    { name = "phases", type = "array<struct<phase_name:string,duration_seconds:int,status:string,context_message:string>>" },
    { name = "enriched_at", type = "string" },
  ]
}

# ============================================================
# Athena workgroup
# ============================================================
module "athena_workgroup" {
  source = "../modules/athena"

  name                    = "${var.project_name}-workgroup"
  description             = "Workgroup for pipeline dashboard queries"
  results_output_location = "s3://${module.data_lake.id}/athena-results/"
}

# ============================================================
# Enrichment Lambda
# ============================================================
data "aws_iam_policy_document" "lambda_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "enrichment_lambda" {
  name               = "${var.project_name}-enrichment-lambda-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}

data "aws_iam_policy_document" "enrichment_lambda" {
  statement {
    sid = "CodePipelineListAccountLevel"
    # ListPipelines / ListActionExecutions has no resource-level support per AWS docs.
    actions   = ["codepipeline:ListPipelines"]
    resources = ["*"]
  }
  statement {
    sid = "CodePipelineRead"
    actions = [
      "codepipeline:GetPipelineExecution",
      "codepipeline:ListActionExecutions",
    ]
    resources = ["arn:aws:codepipeline:*:${local.account_id}:*"]
  }
  statement {
    sid       = "CodeBuildRead"
    actions   = ["codebuild:BatchGetBuilds"]
    resources = ["arn:aws:codebuild:*:${local.account_id}:project/*"]
  }
  statement {
    sid       = "S3WriteEnriched"
    actions   = ["s3:PutObject"]
    resources = ["${module.data_lake.arn}/enriched/*"]
  }
  dynamic "statement" {
    for_each = length(var.hosting_bucket) > 0 ? [1] : []
    content {
      sid       = "S3ReadHostingBucket"
      actions   = ["s3:GetObject"]
      resources = ["arn:aws:s3:::${var.hosting_bucket}/version.json"]
    }
  }
  statement {
    sid     = "DeadLetterQueue"
    actions = ["sqs:SendMessage"]
    resources = [
      aws_sqs_queue.enrichment_dlq.arn,
    ]
  }
  statement {
    sid     = "CloudWatchLogs"
    actions = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = [
      "arn:aws:logs:${local.region}:${local.account_id}:log-group:/aws/lambda/${var.project_name}-enrichment:*",
    ]
  }
}

# Dead-letter queue for the enrichment Lambda. Without this, EventBridge async
# invocation failures vanish after the default 2 retries.
resource "aws_sqs_queue" "enrichment_dlq" {
  name                      = "${var.project_name}-enrichment-dlq"
  message_retention_seconds = 1209600 # 14 days
  sqs_managed_sse_enabled   = true
}

resource "aws_iam_role_policy" "enrichment_lambda" {
  name   = "${var.project_name}-enrichment-lambda-policy"
  role   = aws_iam_role.enrichment_lambda.id
  policy = data.aws_iam_policy_document.enrichment_lambda.json
}

module "enrichment_lambda" {
  source = "../modules/lambda"

  name                   = "${var.project_name}-enrichment"
  role_arn               = aws_iam_role.enrichment_lambda.arn
  source_dir             = "${path.module}/lambda/enrichment"
  dead_letter_target_arn = aws_sqs_queue.enrichment_dlq.arn
  environment = {
    BUCKET_NAME    = module.data_lake.id
    HOSTING_BUCKET = var.hosting_bucket
  }
}

module "pipeline_enrichment_rule" {
  source = "../modules/eventbridge"

  name        = "${var.project_name}-pipeline-enrichment-rule"
  description = "Triggers enrichment Lambda on pipeline state changes"

  event_pattern = jsonencode({
    source        = ["aws.codepipeline"]
    "detail-type" = ["CodePipeline Pipeline Execution State Change"]
  })

  targets = [{
    id  = "EnrichmentLambdaTarget"
    arn = module.enrichment_lambda.arn
  }]
}

module "build_enrichment_rule" {
  source = "../modules/eventbridge"

  name        = "${var.project_name}-build-enrichment-rule"
  description = "Triggers enrichment Lambda on build state changes"

  event_pattern = jsonencode({
    source        = ["aws.codebuild"]
    "detail-type" = ["CodeBuild Build State Change"]
  })

  targets = [{
    id  = "EnrichmentLambdaTarget"
    arn = module.enrichment_lambda.arn
  }]
}

resource "aws_lambda_permission" "pipeline_enrichment" {
  statement_id  = "AllowEventBridgePipelineEnrichment"
  action        = "lambda:InvokeFunction"
  function_name = module.enrichment_lambda.name
  principal     = "events.amazonaws.com"
  source_arn    = module.pipeline_enrichment_rule.rule_arn
}

resource "aws_lambda_permission" "build_enrichment" {
  statement_id  = "AllowEventBridgeBuildEnrichment"
  action        = "lambda:InvokeFunction"
  function_name = module.enrichment_lambda.name
  principal     = "events.amazonaws.com"
  source_arn    = module.build_enrichment_rule.rule_arn
}

# ============================================================
# Stats Lambda + HTTP API
# ============================================================
resource "aws_iam_role" "stats_lambda" {
  name               = "${var.project_name}-stats-lambda-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}

data "aws_iam_policy_document" "stats_lambda" {
  statement {
    actions = [
      "athena:StartQueryExecution",
      "athena:GetQueryExecution",
      "athena:GetQueryResults",
    ]
    resources = [module.athena_workgroup.arn]
  }
  statement {
    actions = ["glue:GetDatabase", "glue:GetTable", "glue:GetPartitions"]
    resources = [
      "arn:aws:glue:${local.region}:${local.account_id}:catalog",
      "arn:aws:glue:${local.region}:${local.account_id}:database/${module.glue_database.database_name}",
      "arn:aws:glue:${local.region}:${local.account_id}:table/${module.glue_database.database_name}/*",
    ]
  }
  statement {
    actions = [
      "s3:GetBucketLocation", "s3:GetObject", "s3:ListBucket", "s3:PutObject",
    ]
    resources = [module.data_lake.arn, "${module.data_lake.arn}/*"]
  }
  statement {
    sid = "CodePipelineListAccountLevel"
    # ListPipelines has no resource-level support per AWS docs.
    actions   = ["codepipeline:ListPipelines"]
    resources = ["*"]
  }
  statement {
    sid = "CodePipelineRead"
    actions = [
      "codepipeline:GetPipeline",
      "codepipeline:GetPipelineState",
      "codepipeline:ListPipelineExecutions",
    ]
    resources = ["arn:aws:codepipeline:*:${local.account_id}:*"]
  }
  dynamic "statement" {
    for_each = length(var.hosting_bucket) > 0 ? [1] : []
    content {
      sid       = "S3ReadHostingBucket"
      actions   = ["s3:GetObject"]
      resources = ["arn:aws:s3:::${var.hosting_bucket}/version.json"]
    }
  }

  # Cross-account read: lets the stats Lambda assume the configured
  # PipelineDashboardReader role in each tracked target account. Empty list
  # of role ARNs means no extra accounts are wired up.
  dynamic "statement" {
    for_each = length([for a in var.tracked_accounts : a if a.role_arn != null && !coalesce(a.synthetic, false)]) > 0 ? [1] : []
    content {
      sid       = "AssumeCrossAccountReader"
      actions   = ["sts:AssumeRole"]
      resources = [for a in var.tracked_accounts : a.role_arn if a.role_arn != null && !coalesce(a.synthetic, false)]
    }
  }

  # Organizations auto-discovery: when enabled, the Lambda enumerates every
  # account in the org, then assumes the reader role in each one. The role
  # exists in every account because the StackSet put it there.
  dynamic "statement" {
    for_each = var.tracked_organization.enabled ? [1] : []
    content {
      sid = "OrganizationsListAccounts"
      actions = [
        "organizations:ListAccounts",
        "organizations:DescribeOrganization",
        "organizations:ListAccountsForParent",
      ]
      resources = ["*"]
    }
  }

  # AssumeRole is scoped to the named role in every account, but additionally
  # constrained to accounts that belong to THIS organization. Without the
  # condition, a stranger could create a role with the same name in their
  # account and trick this Lambda into assuming it.
  dynamic "statement" {
    for_each = var.tracked_organization.enabled ? [1] : []
    content {
      sid       = "AssumeOrgReaderEverywhere"
      actions   = ["sts:AssumeRole"]
      resources = ["arn:aws:iam::*:role/${var.tracked_organization.role_name}"]
      condition {
        test     = "StringEquals"
        variable = "aws:ResourceOrgID"
        values   = [local.org_id]
      }
    }
  }

  statement {
    sid       = "CloudWatchLogs"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["arn:aws:logs:${local.region}:${local.account_id}:log-group:/aws/lambda/${var.project_name}-stats:*"]
  }

  # Chat: read + write the chat state table, and invoke the chat worker
  # Lambda asynchronously. Scoped to just those specific resources.
  statement {
    sid       = "ChatTableAccess"
    actions   = ["dynamodb:PutItem", "dynamodb:GetItem"]
    resources = [aws_dynamodb_table.chat.arn]
  }

  statement {
    sid       = "InvokeChatWorker"
    actions   = ["lambda:InvokeFunction"]
    resources = [module.chat_worker_lambda.arn]
  }
}

resource "aws_iam_role_policy" "stats_lambda" {
  name   = "${var.project_name}-stats-lambda-policy"
  role   = aws_iam_role.stats_lambda.id
  policy = data.aws_iam_policy_document.stats_lambda.json
}

module "stats_lambda" {
  source = "../modules/lambda"

  name        = "${var.project_name}-stats"
  role_arn    = aws_iam_role.stats_lambda.arn
  source_dir  = "${path.module}/lambda/stats"
  timeout     = 60
  memory_size = 512
  environment = {
    DATABASE                  = module.glue_database.database_name
    WORKGROUP                 = module.athena_workgroup.name
    ACCOUNT_ID                = local.account_id
    REGION                    = local.region
    HOSTING_BUCKET            = var.hosting_bucket
    TRACKED_ACCOUNTS          = jsonencode(var.tracked_accounts)
    SYNTHETIC_ACCOUNT_COUNT   = tostring(var.synthetic_account_count)
    SYNTHETIC_ALIASES         = join(",", local.synthetic_aliases)
    SYNTHETIC_REGIONS         = join(",", local.synthetic_regions)
    ORG_ENABLED               = tostring(var.tracked_organization.enabled)
    ORG_ROLE_NAME             = var.tracked_organization.role_name
    ORG_REGIONS               = join(",", var.tracked_organization.regions)
    ORG_EXCLUDE_ACCOUNTS      = join(",", var.tracked_organization.exclude_account_ids)
    CHAT_TABLE_NAME           = aws_dynamodb_table.chat.name
    CHAT_WORKER_FUNCTION_NAME = module.chat_worker_lambda.name
    # CORS allow-origin echoed in every Lambda response. The dashboard runs
    # locally via Vite (which proxies + signs requests with SigV4), so the
    # browser never hits API Gateway directly. We still set this for
    # operators who want to debug the API in a browser console.
    CORS_ALLOW_ORIGIN = var.cors_allow_origin
  }
}

module "stats_api" {
  source = "../modules/api_gateway"

  name                 = "${var.project_name}-stats-api"
  lambda_function_name = module.stats_lambda.name
  lambda_invoke_arn    = module.stats_lambda.invoke_arn
  cors_allow_origins   = [var.cors_allow_origin]
  # AWS_IAM (default in the module) requires every caller to sign requests
  # with SigV4 and have execute-api:Invoke on the route ARN. The module
  # outputs a managed policy operators can attach to themselves.
  routes = [
    "GET /stats",
    "GET /pipelines",
    "GET /accounts",
    "POST /chat",
    "GET /chat/{chatId}",
  ]
  cors_allow_methods = ["GET", "POST", "OPTIONS"]
}

# ============================================================
# CloudWatch alarms — surface Lambda failures (otherwise enrichment errors
# silently drop events and the dashboard quietly shows stale data).
# ============================================================
resource "aws_cloudwatch_metric_alarm" "stats_lambda_errors" {
  alarm_name          = "${var.project_name}-stats-lambda-errors"
  alarm_description   = "Stats Lambda is erroring; the dashboard is likely broken."
  namespace           = "AWS/Lambda"
  metric_name         = "Errors"
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  dimensions = {
    FunctionName = module.stats_lambda.name
  }
}

resource "aws_cloudwatch_metric_alarm" "enrichment_lambda_errors" {
  alarm_name          = "${var.project_name}-enrichment-lambda-errors"
  alarm_description   = "Enrichment Lambda is failing; check the DLQ for dropped events."
  namespace           = "AWS/Lambda"
  metric_name         = "Errors"
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  dimensions = {
    FunctionName = module.enrichment_lambda.name
  }
}

resource "aws_cloudwatch_metric_alarm" "enrichment_dlq_depth" {
  alarm_name          = "${var.project_name}-enrichment-dlq-not-empty"
  alarm_description   = "Enrichment DLQ has dropped events. Inspect and replay or purge."
  namespace           = "AWS/SQS"
  metric_name         = "ApproximateNumberOfMessagesVisible"
  statistic           = "Maximum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  dimensions = {
    QueueName = aws_sqs_queue.enrichment_dlq.name
  }
}
