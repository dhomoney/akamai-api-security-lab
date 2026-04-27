# Noname (Akamai API Security) sensor/connector running as an ECS task.
# The sensor connects outbound to the Noname SaaS tenant and collects API
# traffic metadata from Kong, NGINX, and MuleSoft via their integration APIs.

resource "aws_iam_role" "noname_task_exec" {
  name = "${var.project_name}-noname-task-exec-role"

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

resource "aws_iam_role_policy_attachment" "noname_task_exec" {
  role       = aws_iam_role.noname_task_exec.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_ssm_parameter" "noname_tenant_url" {
  name  = "/${var.project_name}/noname/tenant_url"
  type  = "SecureString"
  value = var.noname_tenant_url

  tags = var.tags
}

resource "aws_ssm_parameter" "noname_api_key" {
  name  = "/${var.project_name}/noname/api_key"
  type  = "SecureString"
  value = var.noname_api_key

  tags = var.tags
}

resource "aws_iam_policy" "noname_ssm" {
  name = "${var.project_name}-noname-ssm-policy"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = ["ssm:GetParameters", "ssm:GetParameter"]
      Resource = [
        aws_ssm_parameter.noname_tenant_url.arn,
        aws_ssm_parameter.noname_api_key.arn
      ]
    }]
  })
}

resource "aws_iam_role_policy_attachment" "noname_ssm" {
  role       = aws_iam_role.noname_task_exec.name
  policy_arn = aws_iam_policy.noname_ssm.arn
}

resource "aws_cloudwatch_log_group" "noname" {
  name              = "/ecs/${var.project_name}/noname"
  retention_in_days = 7

  tags = var.tags
}

resource "aws_ecs_task_definition" "noname" {
  family                   = "${var.project_name}-noname"
  requires_compatibilities = ["EC2"]
  network_mode             = "bridge"
  execution_role_arn       = aws_iam_role.noname_task_exec.arn

  # TODO: Replace image with the Noname connector image provided by Akamai.
  # Obtain the image from your Noname SaaS tenant's deployment guide.
  container_definitions = jsonencode([
    {
      name      = "noname-sensor"
      image     = var.noname_sensor_image
      essential = true

      portMappings = [
        { containerPort = 8080, hostPort = 8080, protocol = "tcp" }
      ]

      secrets = [
        { name = "NONAME_TENANT_URL", valueFrom = aws_ssm_parameter.noname_tenant_url.arn },
        { name = "NONAME_API_KEY",    valueFrom = aws_ssm_parameter.noname_api_key.arn }
      ]

      environment = [
        { name = "KONG_ADMIN_URL",   value = var.kong_admin_url },
        { name = "NGINX_STATUS_URL", value = var.nginx_status_url },
        { name = "MULESOFT_API_URL", value = var.mulesoft_api_url }
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.noname.name
          "awslogs-region"        = "us-east-2"
          "awslogs-stream-prefix" = "noname"
        }
      }

      memory = 512
      cpu    = 256
    }
  ])

  tags = var.tags
}

resource "aws_ecs_service" "noname" {
  name            = "${var.project_name}-noname"
  cluster         = var.cluster_id
  task_definition = aws_ecs_task_definition.noname.arn
  desired_count   = 1

  capacity_provider_strategy {
    capacity_provider = var.capacity_provider
    weight            = 1
  }

  tags = var.tags
}
