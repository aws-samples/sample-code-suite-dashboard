resource "aws_apigatewayv2_api" "this" {
  name          = var.name
  protocol_type = "HTTP"

  cors_configuration {
    allow_origins = var.cors_allow_origins
    allow_methods = var.cors_allow_methods
    allow_headers = var.cors_allow_headers
  }
}

resource "aws_apigatewayv2_integration" "lambda" {
  api_id                 = aws_apigatewayv2_api.this.id
  integration_type       = "AWS_PROXY"
  integration_uri        = var.lambda_invoke_arn
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_route" "this" {
  for_each           = toset(var.routes)
  api_id             = aws_apigatewayv2_api.this.id
  route_key          = each.value
  target             = "integrations/${aws_apigatewayv2_integration.lambda.id}"
  authorization_type = var.authorization_type
}

# Managed IAM policy that grants `execute-api:Invoke` on this API's routes.
# Attach it to any IAM principal (user, role, SSO permission set) that needs
# to call the API. The dashboard's Vite dev-server middleware signs requests
# with SigV4 using the developer's local credential chain, so a developer
# only needs this policy attached to the identity they're logged in as.
resource "aws_iam_policy" "invoke" {
  name        = "${var.name}-invoke"
  description = "Grants execute-api:Invoke on every route of the ${var.name} HTTP API."
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "execute-api:Invoke"
      Resource = "${aws_apigatewayv2_api.this.execution_arn}/*/*"
    }]
  })
}

# Access logs for the default stage. Required by checkov CKV_AWS_76 and useful
# for incident response — without these, the API is effectively unauditable.
resource "aws_cloudwatch_log_group" "access" {
  name              = "/aws/apigateway/${var.name}"
  retention_in_days = var.access_log_retention_days

  # checkov:skip=CKV_AWS_158: Access logs contain no secrets and AWS-managed
  # encryption is already on. Customer KMS keys add ~$1/mo per key for no
  # marginal benefit on this demo workload.
  # checkov:skip=CKV_AWS_338: Retention is operator-configurable via
  # var.access_log_retention_days. Default of 30 days is intentional for a
  # demo; bump it in tfvars for longer-lived deployments.
}

resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.this.id
  name        = "$default"
  auto_deploy = true

  access_log_settings {
    destination_arn = aws_cloudwatch_log_group.access.arn
    format = jsonencode({
      requestId      = "$context.requestId"
      sourceIp       = "$context.identity.sourceIp"
      userAgent      = "$context.identity.userAgent"
      requestTime    = "$context.requestTime"
      httpMethod     = "$context.httpMethod"
      routeKey       = "$context.routeKey"
      status         = "$context.status"
      protocol       = "$context.protocol"
      responseLength = "$context.responseLength"
      integrationErr = "$context.integrationErrorMessage"
    })
  }

  # Default throttling. Protects the backing Lambda from spike + sustained
  # abuse on a still-public endpoint.
  default_route_settings {
    throttling_burst_limit = var.throttle_burst_limit
    throttling_rate_limit  = var.throttle_rate_limit
  }
}

resource "aws_lambda_permission" "apigw" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = var.lambda_function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.this.execution_arn}/*/*"
}
