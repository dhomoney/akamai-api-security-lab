# Anypoint Flex Gateway running as an ECS task in connected mode.
# The registration.yaml (generated via 'docker run --entrypoint flexctl ... registration create')
# is stored in Secrets Manager and injected into the container at startup by entrypoint.sh.

resource "aws_lb" "mulesoft" {
  name               = "${var.project_name}-mule-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [var.alb_sg_id]
  subnets            = var.public_subnet_ids

  tags = merge(var.tags, { Name = "${var.project_name}-mule-alb" })
}

resource "aws_lb_target_group" "mulesoft" {
  name        = "${var.project_name}-mule-tg"
  port        = 8081
  protocol    = "HTTP"
  vpc_id      = var.vpc_id
  target_type = "instance"

  health_check {
    path                = "/"
    healthy_threshold   = 2
    unhealthy_threshold = 5
    interval            = 30
    matcher             = "200-499"
  }

  tags = var.tags
}

resource "aws_lb_listener" "mulesoft_http" {
  load_balancer_arn = aws_lb.mulesoft.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.mulesoft.arn
  }

  tags = var.tags
}

resource "aws_iam_role" "mulesoft_task_exec" {
  name = "${var.project_name}-mule-task-exec-role"

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

resource "aws_iam_role_policy_attachment" "mulesoft_task_exec" {
  role       = aws_iam_role.mulesoft_task_exec.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_iam_policy" "mulesoft_secrets" {
  name = "${var.project_name}-mule-secrets-policy"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["secretsmanager:GetSecretValue"]
      Resource = [var.registration_yaml_secret_arn]
    }]
  })
}

resource "aws_iam_role_policy_attachment" "mulesoft_secrets" {
  role       = aws_iam_role.mulesoft_task_exec.name
  policy_arn = aws_iam_policy.mulesoft_secrets.arn
}

resource "aws_cloudwatch_log_group" "mulesoft" {
  name              = "/ecs/${var.project_name}/mulesoft"
  retention_in_days = 7

  tags = var.tags
}

resource "aws_ecs_task_definition" "mulesoft" {
  family                   = "${var.project_name}-mulesoft"
  requires_compatibilities = ["EC2"]
  network_mode             = "bridge"
  execution_role_arn       = aws_iam_role.mulesoft_task_exec.arn

  container_definitions = jsonencode([
    {
      name      = "mulesoft"
      image     = var.mule_image
      essential = true

      portMappings = [
        { containerPort = 8081, hostPort = 8081, protocol = "tcp" }
      ]

      secrets = [
        {
          name      = "FLEX_REGISTRATION_YAML"
          valueFrom = var.registration_yaml_secret_arn
        }
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.mulesoft.name
          "awslogs-region"        = "us-east-2"
          "awslogs-stream-prefix" = "mulesoft"
        }
      }

      memory = 1024
      cpu    = 512
    }
  ])

  tags = var.tags
}

resource "aws_ecs_service" "mulesoft" {
  name                              = "${var.project_name}-mulesoft"
  cluster                           = var.cluster_id
  task_definition                   = aws_ecs_task_definition.mulesoft.arn
  desired_count                     = 1
  health_check_grace_period_seconds = 600

  capacity_provider_strategy {
    capacity_provider = var.capacity_provider
    weight            = 1
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.mulesoft.arn
    container_name   = "mulesoft"
    container_port   = 8081
  }

  tags = var.tags
}
