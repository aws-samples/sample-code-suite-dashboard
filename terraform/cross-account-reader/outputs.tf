output "role_arn" {
  value       = aws_iam_role.this.arn
  description = "Paste this ARN into the central stack's tracked_accounts variable."
}

output "target_account_id" {
  value       = data.aws_caller_identity.current.account_id
  description = "12-digit AWS account ID of this target account."
}

output "tracked_accounts_snippet" {
  description = "Drop this entry into terraform/stacks/pipeline-dashboard/variables.tf -> tracked_accounts."
  value = jsonencode({
    account_id = data.aws_caller_identity.current.account_id
    alias      = "REPLACE_ME"
    region     = var.region
    role_arn   = aws_iam_role.this.arn
  })
}
