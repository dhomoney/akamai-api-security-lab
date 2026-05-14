data "aws_region" "current" {}

data "aws_kinesis_stream" "noname" {
  count = var.kinesis_stream_arn != "" ? 1 : 0
  name  = element(split("/", var.kinesis_stream_arn), 1)
}

# ── VPC Link — lets API Gateway reach the private apps ALB ────────────────────

resource "aws_security_group" "vpc_link" {
  name        = "${var.project_name}-api-gw-vpc-link-sg"
  description = "Egress from API Gateway VPC Link to apps ALB (JuiceShop port 3000)"
  vpc_id      = var.vpc_id

  egress {
    from_port   = 3000
    to_port     = 3000
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "JuiceShop via apps ALB"
  }

  tags = merge(var.tags, { Name = "${var.project_name}-api-gw-vpc-link-sg" })
}

# Allow the VPC Link SG to reach the apps internal ALB on port 3000.
resource "aws_security_group_rule" "apps_alb_from_api_gw" {
  type                     = "ingress"
  from_port                = 3000
  to_port                  = 3000
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.vpc_link.id
  security_group_id        = var.apps_alb_sg_id
  description              = "API Gateway VPC Link to JuiceShop"
}

resource "aws_apigatewayv2_vpc_link" "main" {
  name               = "${var.project_name}-api-gw-vpc-link"
  security_group_ids = [aws_security_group.vpc_link.id]
  subnet_ids         = var.private_subnet_ids

  tags = merge(var.tags, { Name = "${var.project_name}-api-gw-vpc-link" })
}

# ── HTTP API ───────────────────────────────────────────────────────────────────

resource "aws_apigatewayv2_api" "main" {
  name          = "${var.project_name}-api-gw"
  protocol_type = "HTTP"

  tags = merge(var.tags, { Name = "${var.project_name}-api-gw" })
}

# Integration: HTTP_PROXY through VPC Link to apps ALB listener (JuiceShop).
# overwrite:path strips the /shop/ prefix so JuiceShop sees /api/... not /shop/api/...
resource "aws_apigatewayv2_integration" "juiceshop" {
  api_id             = aws_apigatewayv2_api.main.id
  integration_type   = "HTTP_PROXY"
  integration_method = "ANY"
  integration_uri    = var.juiceshop_alb_listener_arn
  connection_type    = "VPC_LINK"
  connection_id      = aws_apigatewayv2_vpc_link.main.id

  request_parameters = {
    "overwrite:path" = "/$request.path.proxy"
  }
}

resource "aws_apigatewayv2_route" "shop" {
  api_id    = aws_apigatewayv2_api.main.id
  route_key = "ANY /shop/{proxy+}"
  target    = "integrations/${aws_apigatewayv2_integration.juiceshop.id}"
}

# ── Logging ───────────────────────────────────────────────────────────────────

resource "aws_cloudwatch_log_group" "api_gw" {
  name              = "/aws/apigateway/${var.project_name}"
  retention_in_days = 7

  tags = var.tags
}

resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.main.id
  name        = "$default"
  auto_deploy = true

  # Noname AWS Connector reads this log group via Kinesis subscription filter.
  # The [NONAME]...[NONAME] wrapper is required for the Forwarder Lambda to parse entries.
  access_log_settings {
    destination_arn = aws_cloudwatch_log_group.api_gw.arn
    format          = "[NONAME]$context.requestId,$context.identity.sourceIp,$context.identity.caller,$context.identity.user,$context.requestTime,$context.httpMethod,$context.path,$context.status,$context.protocol,$context.responseLength,$context.domainName,$context.accountId[NONAME]"
  }

  tags = var.tags
}

# ── Kinesis subscription (wired once noname_connector Forwarder is deployed) ──

resource "aws_iam_role" "cw_to_kinesis" {
  count = var.kinesis_stream_arn != "" ? 1 : 0
  name  = "${var.project_name}-api-gw-cw-kinesis-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "logs.${data.aws_region.current.name}.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = var.tags
}

resource "aws_iam_role_policy" "cw_to_kinesis" {
  count = var.kinesis_stream_arn != "" ? 1 : 0
  name  = "put-records"
  role  = aws_iam_role.cw_to_kinesis[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat(
      [{
        Effect   = "Allow"
        Action   = ["kinesis:PutRecord"]
        Resource = var.kinesis_stream_arn
      }],
      data.aws_kinesis_stream.noname[0].kms_key_id != "" ? [{
        Effect   = "Allow"
        Action   = ["kms:GenerateDataKey", "kms:Decrypt"]
        Resource = data.aws_kinesis_stream.noname[0].kms_key_id
      }] : []
    )
  })
}

resource "aws_cloudwatch_log_subscription_filter" "noname" {
  count           = var.kinesis_stream_arn != "" ? 1 : 0
  name            = "${var.project_name}-noname-api-gw-filter"
  log_group_name  = aws_cloudwatch_log_group.api_gw.name
  filter_pattern  = ""
  destination_arn = var.kinesis_stream_arn
  role_arn        = aws_iam_role.cw_to_kinesis[0].arn

  depends_on = [aws_apigatewayv2_stage.default]
}
