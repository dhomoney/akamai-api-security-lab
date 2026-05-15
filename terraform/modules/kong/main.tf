locals {
  kong_declarative_config = (var.noname_plugin_enabled && var.noname_source_key != "") ? join("\n", [
    "_format_version: \"3.0\"",
    "plugins:",
    "  - name: nonamesecurity",
    "    config:",
    "      NN_ENGINE_URL: \"${var.noname_engine_url}?structure=base64-payload\"",
    "      NN_SOURCE_KEY: \"${var.noname_source_key}\"",
    "      NN_SOURCE_INDEX: ${var.noname_source_index}",
    "      NN_SOURCE_TYPE: 7",
  ]) : "_format_version: \"3.0\""
}

resource "aws_lb" "kong" {
  name               = "${var.project_name}-kong-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [var.alb_sg_id]
  subnets            = var.public_subnet_ids

  tags = merge(var.tags, { Name = "${var.project_name}-kong-alb" })
}

resource "aws_lb_target_group" "kong_proxy" {
  name        = "${var.project_name}-kong-proxy-tg"
  port        = 8000
  protocol    = "HTTP"
  vpc_id      = var.vpc_id
  target_type = "instance"

  # Kong's proxy port returns 404 to any unmapped path. /status only exists on
  # the Admin API (port 8001), so we accept any 2xx-4xx response here as proof
  # the proxy is reachable. Without this matcher ECS perpetually replaces
  # tasks because every health probe sees 404 and marks the target unhealthy.
  health_check {
    path                = "/"
    matcher             = "200-499"
    healthy_threshold   = 2
    unhealthy_threshold = 3
    interval            = 30
  }

  tags = var.tags
}

resource "aws_lb_listener" "kong_http" {
  load_balancer_arn = aws_lb.kong.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.kong_proxy.arn
  }
}

resource "aws_lb_target_group" "kong_admin" {
  name        = "${var.project_name}-kong-admin-tg"
  port        = 8001
  protocol    = "HTTP"
  vpc_id      = var.vpc_id
  target_type = "instance"

  health_check {
    path                = "/status"
    healthy_threshold   = 2
    unhealthy_threshold = 3
    interval            = 30
  }

  tags = var.tags
}

resource "aws_lb_listener" "kong_admin" {
  load_balancer_arn = aws_lb.kong.arn
  port              = 8001
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.kong_admin.arn
  }
}

resource "aws_iam_role" "kong_task_exec" {
  name = "${var.project_name}-kong-task-exec-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
    }]
  })

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "kong_task_exec" {
  role       = aws_iam_role.kong_task_exec.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_cloudwatch_log_group" "kong" {
  name              = "/ecs/${var.project_name}/kong"
  retention_in_days = 7

  tags = var.tags
}

resource "aws_ecs_task_definition" "kong" {
  family                   = "${var.project_name}-kong"
  requires_compatibilities = ["EC2"]
  network_mode             = "bridge"
  execution_role_arn       = aws_iam_role.kong_task_exec.arn

  container_definitions = jsonencode([
    {
      name      = "kong"
      image     = var.kong_image
      essential = true

      portMappings = [
        { containerPort = 8000, hostPort = 8000, protocol = "tcp" },
        { containerPort = 8001, hostPort = 8001, protocol = "tcp" },
        { containerPort = 8443, hostPort = 8443, protocol = "tcp" }
      ]

      environment = concat(
        [
          { name = "KONG_DATABASE", value = "off" },
          { name = "KONG_DECLARATIVE_CONFIG_STRING", value = local.kong_declarative_config },
          { name = "KONG_PROXY_LISTEN", value = "0.0.0.0:8000, 0.0.0.0:8443 ssl" },
          { name = "KONG_ADMIN_LISTEN", value = "0.0.0.0:8001" },
          { name = "KONG_LOG_LEVEL", value = "info" }
        ],
        var.noname_plugin_enabled ? [{ name = "KONG_PLUGINS", value = "bundled,nonamesecurity" }] : []
      )

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.kong.name
          "awslogs-region"        = "us-east-2"
          "awslogs-stream-prefix" = "kong"
        }
      }

      memory = 512
      cpu    = 256
    }
  ])

  tags = var.tags
}

resource "aws_ecs_service" "kong" {
  name            = "${var.project_name}-kong"
  cluster         = var.cluster_id
  task_definition = aws_ecs_task_definition.kong.arn
  desired_count   = 1

  capacity_provider_strategy {
    capacity_provider = var.capacity_provider
    weight            = 1
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.kong_proxy.arn
    container_name   = "kong"
    container_port   = 8000
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.kong_admin.arn
    container_name   = "kong"
    container_port   = 8001
  }

  tags = var.tags
}
