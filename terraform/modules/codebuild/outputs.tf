output "name" {
  value = aws_codebuild_project.this.name
}

output "arn" {
  value = aws_codebuild_project.this.arn
}

output "log_group_name" {
  value = aws_cloudwatch_log_group.build.name
}

output "log_group_arn" {
  value = aws_cloudwatch_log_group.build.arn
}
