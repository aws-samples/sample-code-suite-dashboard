resource "aws_cloudwatch_event_rule" "this" {
  name          = var.name
  description   = var.description
  event_pattern = var.event_pattern
}

resource "aws_cloudwatch_event_target" "this" {
  for_each = { for t in var.targets : t.id => t }

  rule       = aws_cloudwatch_event_rule.this.name
  target_id  = each.value.id
  arn        = each.value.arn
  role_arn   = each.value.role_arn
  input      = each.value.input
  input_path = each.value.input_path

  dynamic "input_transformer" {
    for_each = each.value.input_transformer == null ? [] : [each.value.input_transformer]
    content {
      input_paths    = input_transformer.value.input_paths
      input_template = input_transformer.value.input_template
    }
  }
}
