output "id" {
  value = aws_apigatewayv2_api.this.id
}

output "endpoint" {
  value = aws_apigatewayv2_api.this.api_endpoint
}

output "execution_arn" {
  description = "execution_arn of the API. Append /*/* (e.g. \"<execution_arn>/*/*\") as the Resource for execute-api:Invoke statements."
  value       = aws_apigatewayv2_api.this.execution_arn
}

output "invoke_policy_arn" {
  description = "ARN of the managed IAM policy granting execute-api:Invoke on every route of this API. Attach to any principal that needs to call the API."
  value       = aws_iam_policy.invoke.arn
}
