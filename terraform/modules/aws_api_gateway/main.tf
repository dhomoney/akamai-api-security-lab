data "aws_region" "current" {}

data "aws_kinesis_stream" "noname" {
  count = var.kinesis_stream_arn != "" ? 1 : 0
  name  = element(split("/", var.kinesis_stream_arn), 1)
}

# ── IAM — account-level CloudWatch logging role for REST API Gateway ──────────

resource "aws_iam_role" "api_gw_cw" {
  name = "${var.project_name}-api-gw-cloudwatch-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "apigateway.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "api_gw_cw" {
  role       = aws_iam_role.api_gw_cw.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonAPIGatewayPushToCloudWatchLogs"
}

# Account-level singleton — sets the CloudWatch logs delivery role for this AWS account.
resource "aws_api_gateway_account" "main" {
  cloudwatch_role_arn = aws_iam_role.api_gw_cw.arn
}

# ── NLB — REST API V1 VPC Links require NLB (not ALB) ────────────────────────

resource "aws_lb" "nlb" {
  name               = "${var.project_name}-apigw-nlb"
  internal           = true
  load_balancer_type = "network"
  subnets            = var.private_subnet_ids

  tags = merge(var.tags, { Name = "${var.project_name}-apigw-nlb" })
}

resource "aws_lb_target_group" "juiceshop" {
  name        = "${var.project_name}-apigw-js-tg"
  port        = 3000
  protocol    = "TCP"
  vpc_id      = var.vpc_id
  target_type = "ip"

  health_check {
    protocol            = "TCP"
    healthy_threshold   = 2
    unhealthy_threshold = 2
    interval            = 30
  }

  tags = var.tags
}

resource "aws_lb_listener" "juiceshop" {
  load_balancer_arn = aws_lb.nlb.arn
  port              = 3000
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.juiceshop.arn
  }
}

resource "aws_lb_target_group_attachment" "juiceshop" {
  target_group_arn = aws_lb_target_group.juiceshop.arn
  target_id        = var.apps_instance_ip
  port             = 3000
}

# NLBs are L4-transparent — source IPs arriving at the target are the NLB node
# IPs, which live in the VPC. Open port 3000 from the VPC CIDR so NLB→instance
# traffic is not blocked by the apps instance SG.
resource "aws_security_group_rule" "apps_instance_from_nlb" {
  type              = "ingress"
  from_port         = 3000
  to_port           = 3000
  protocol          = "tcp"
  cidr_blocks       = [var.vpc_cidr]
  security_group_id = var.apps_instance_sg_id
  description       = "JuiceShop via API Gateway NLB"
}

# ── VPC Link ──────────────────────────────────────────────────────────────────

resource "aws_api_gateway_vpc_link" "main" {
  name        = "${var.project_name}-api-gw-vpc-link"
  target_arns = [aws_lb.nlb.arn]

  tags = merge(var.tags, { Name = "${var.project_name}-api-gw-vpc-link" })
}

# ── REST API (V1) ─────────────────────────────────────────────────────────────

resource "aws_api_gateway_rest_api" "main" {
  name = "${var.project_name}-api-gw"

  tags = merge(var.tags, { Name = "${var.project_name}-api-gw" })
}

resource "aws_api_gateway_resource" "shop" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  parent_id   = aws_api_gateway_rest_api.main.root_resource_id
  path_part   = "shop"
}

resource "aws_api_gateway_resource" "proxy" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  parent_id   = aws_api_gateway_resource.shop.id
  path_part   = "{proxy+}"
}

resource "aws_api_gateway_method" "proxy_any" {
  rest_api_id   = aws_api_gateway_rest_api.main.id
  resource_id   = aws_api_gateway_resource.proxy.id
  http_method   = "ANY"
  authorization = "NONE"

  request_parameters = {
    "method.request.path.proxy" = true
  }
}

resource "aws_api_gateway_integration" "juiceshop" {
  rest_api_id             = aws_api_gateway_rest_api.main.id
  resource_id             = aws_api_gateway_resource.proxy.id
  http_method             = aws_api_gateway_method.proxy_any.http_method
  integration_http_method = "ANY"
  type                    = "HTTP_PROXY"
  uri                     = "http://${aws_lb.nlb.dns_name}:3000/{proxy}"
  connection_type         = "VPC_LINK"
  connection_id           = aws_api_gateway_vpc_link.main.id

  request_parameters = {
    "integration.request.path.proxy" = "method.request.path.proxy"
  }
}

resource "aws_api_gateway_deployment" "main" {
  rest_api_id = aws_api_gateway_rest_api.main.id

  triggers = {
    redeployment = sha1(jsonencode([
      aws_api_gateway_resource.shop.id,
      aws_api_gateway_resource.proxy.id,
      aws_api_gateway_method.proxy_any.id,
      aws_api_gateway_integration.juiceshop.id,
      aws_api_gateway_integration.juiceshop.uri,
      aws_api_gateway_integration.juiceshop.connection_id,
    ]))
  }

  lifecycle {
    create_before_destroy = true
  }

  depends_on = [aws_api_gateway_integration.juiceshop]
}

# ── Log groups ────────────────────────────────────────────────────────────────

resource "aws_cloudwatch_log_group" "api_gw" {
  name              = "/aws/apigateway/${var.project_name}"
  retention_in_days = 7

  tags = var.tags
}

# REST API V1 auto-names execution logs API-Gateway-Execution-Logs_{id}/{stage}.
# Creating the resource here controls retention and allows the Kinesis subscription.
resource "aws_cloudwatch_log_group" "api_gw_execution" {
  name              = "API-Gateway-Execution-Logs_${aws_api_gateway_rest_api.main.id}/lab"
  retention_in_days = 7

  tags = var.tags
}

# ── Stage ─────────────────────────────────────────────────────────────────────

resource "aws_api_gateway_stage" "lab" {
  deployment_id = aws_api_gateway_deployment.main.id
  rest_api_id   = aws_api_gateway_rest_api.main.id
  stage_name    = "lab"

  # Noname Forwarder Lambda pairs access log entries (metadata) with execution
  # log entries (data tracing bodies) by requestId via DynamoDB. Both streams
  # must be subscribed to Kinesis for packetPairsSent > 0.
  access_log_settings {
    destination_arn = aws_cloudwatch_log_group.api_gw.arn
    format          = "[NONAME]$context.requestId,$context.identity.sourceIp,$context.identity.caller,$context.identity.user,$context.requestTime,$context.httpMethod,$context.path,$context.status,$context.protocol,$context.responseLength,$context.domainName,$context.accountId[NONAME]"
  }

  depends_on = [aws_api_gateway_account.main, aws_cloudwatch_log_group.api_gw_execution]

  tags = var.tags
}

# Enable execution logging + data tracing on every method (required for packet pairing).
resource "aws_api_gateway_method_settings" "all" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  stage_name  = aws_api_gateway_stage.lab.stage_name
  method_path = "*/*"

  settings {
    logging_level      = "INFO"
    data_trace_enabled = true
  }
}

# ── Kinesis subscription filters ──────────────────────────────────────────────

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

resource "aws_cloudwatch_log_subscription_filter" "noname_access" {
  count           = var.kinesis_stream_arn != "" ? 1 : 0
  name            = "${var.project_name}-noname-api-gw-access-filter"
  log_group_name  = aws_cloudwatch_log_group.api_gw.name
  filter_pattern  = ""
  destination_arn = var.kinesis_stream_arn
  role_arn        = aws_iam_role.cw_to_kinesis[0].arn

  depends_on = [aws_api_gateway_stage.lab]
}

resource "aws_cloudwatch_log_subscription_filter" "noname_execution" {
  count           = var.kinesis_stream_arn != "" ? 1 : 0
  name            = "${var.project_name}-noname-api-gw-execution-filter"
  log_group_name  = aws_cloudwatch_log_group.api_gw_execution.name
  filter_pattern  = ""
  destination_arn = var.kinesis_stream_arn
  role_arn        = aws_iam_role.cw_to_kinesis[0].arn

  depends_on = [aws_api_gateway_stage.lab]
}
