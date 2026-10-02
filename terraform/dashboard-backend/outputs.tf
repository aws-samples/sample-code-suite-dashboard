output "data_lake_bucket_name" {
  value = module.data_lake.id
}

output "athena_workgroup_name" {
  value = module.athena_workgroup.name
}

output "glue_database_name" {
  value = module.glue_database.database_name
}

output "pipeline_events_stream_name" {
  value = module.pipeline_events_stream.name
}

output "build_events_stream_name" {
  value = module.build_events_stream.name
}

output "stats_api_url" {
  value = "${module.stats_api.endpoint}/stats"
}

output "pipelines_api_url" {
  value = "${module.stats_api.endpoint}/pipelines"
}

output "accounts_api_url" {
  value = "${module.stats_api.endpoint}/accounts"
}

output "stats_lambda_role_arn" {
  description = "Role ARN of the central stats Lambda. Use this as central_lambda_role_arn when deploying cross-account-reader into target accounts."
  value       = aws_iam_role.stats_lambda.arn
}

output "api_invoke_policy_arn" {
  description = <<-EOT
    Managed IAM policy that grants execute-api:Invoke on every stats-API
    route. Attach this to any IAM principal that needs to call the API
    (typically the IAM user / SSO permission set you run `make run-dashboard`
    as). Without it, signed requests come back 403.
  EOT
  value       = module.stats_api.invoke_policy_arn
}

output "api_execution_arn" {
  description = "execution_arn of the stats API. Append /*/* to build your own invoke policy."
  value       = module.stats_api.execution_arn
}

output "enrichment_dlq_url" {
  description = "Dead-letter queue URL for failed enrichment events."
  value       = aws_sqs_queue.enrichment_dlq.url
}
