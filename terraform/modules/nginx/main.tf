resource "aws_lb" "nginx" {
  name               = "${var.project_name}-nginx-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [var.alb_sg_id]
  subnets            = var.public_subnet_ids

  tags = merge(var.tags, { Name = "${var.project_name}-nginx-alb" })
}

resource "aws_lb_target_group" "nginx" {
  name        = "${var.project_name}-nginx-tg"
  port        = 80
  protocol    = "HTTP"
  vpc_id      = var.vpc_id
  target_type = "instance"

  health_check {
    path                = "/health"
    healthy_threshold   = 2
    unhealthy_threshold = 3
    interval            = 30
  }

  tags = var.tags
}

resource "aws_lb_listener" "nginx_http" {
  load_balancer_arn = aws_lb.nginx.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.nginx.arn
  }
}

resource "aws_iam_role" "nginx_task_exec" {
  name = "${var.project_name}-nginx-task-exec-role"

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

resource "aws_iam_role_policy_attachment" "nginx_task_exec" {
  role       = aws_iam_role.nginx_task_exec.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_cloudwatch_log_group" "nginx" {
  name              = "/ecs/${var.project_name}/nginx"
  retention_in_days = 7

  tags = var.tags
}

resource "aws_ecs_task_definition" "nginx" {
  family                   = "${var.project_name}-nginx"
  requires_compatibilities = ["EC2"]
  network_mode             = "bridge"
  execution_role_arn       = aws_iam_role.nginx_task_exec.arn

  container_definitions = jsonencode([
    {
      name      = "nginx"
      image     = var.nginx_image
      essential = true

      portMappings = [
        { containerPort = 80, hostPort = 8080, protocol = "tcp" },
        { containerPort = 443, hostPort = 8443, protocol = "tcp" }
      ]

      environment = concat(
        [{ name = "APPS_ALB_DNS", value = var.apps_alb_dns }],
        var.noname_source_key != "" ? [
          { name = "NN_SOURCE_KEY",   value = var.noname_source_key },
          { name = "NN_SOURCE_INDEX", value = tostring(var.noname_source_index) }
        ] : []
      )

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.nginx.name
          "awslogs-region"        = "us-east-2"
          "awslogs-stream-prefix" = "nginx"
        }
      }

      memory = 256
      cpu    = 128
    }
  ])

  tags = var.tags
}

resource "aws_ecs_service" "nginx" {
  name            = "${var.project_name}-nginx"
  cluster         = var.cluster_id
  task_definition = aws_ecs_task_definition.nginx.arn
  desired_count   = 1

  capacity_provider_strategy {
    capacity_provider = var.capacity_provider
    weight            = 1
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.nginx.arn
    container_name   = "nginx"
    container_port   = 80
  }

  tags = var.tags
}
