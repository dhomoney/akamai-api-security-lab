resource "aws_iam_role" "exec" {
  name = "${var.project_name}-traffic-exec-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "exec" {
  role       = aws_iam_role.exec.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_cloudwatch_log_group" "traffic" {
  name              = "/ecs/${var.project_name}/traffic"
  retention_in_days = 3

  tags = var.tags
}

resource "aws_ecs_task_definition" "traffic" {
  family                   = "${var.project_name}-traffic"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = "512"
  memory                   = "1024"
  execution_role_arn       = aws_iam_role.exec.arn

  container_definitions = jsonencode([{
    name      = "locust"
    image     = var.traffic_image
    essential = true

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.traffic.name
        "awslogs-region"        = var.aws_region
        "awslogs-stream-prefix" = "locust"
      }
    }
  }])

  tags = var.tags
}
