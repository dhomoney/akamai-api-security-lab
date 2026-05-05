data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# ── Security groups ────────────────────────────────────────────────────────────

resource "aws_security_group" "apps_alb" {
  name        = "${var.project_name}-apps-alb-sg"
  description = "Internal ALB for vulnerable apps - inbound from gateway ECS SG"
  vpc_id      = var.vpc_id

  dynamic "ingress" {
    for_each = var.app_ports
    content {
      description     = "App ${ingress.key} from gateways"
      from_port       = ingress.value
      to_port         = ingress.value
      protocol        = "tcp"
      security_groups = [var.ecs_sg_id]
    }
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, { Name = "${var.project_name}-apps-alb-sg" })
}

resource "aws_security_group" "apps_instance" {
  name        = "${var.project_name}-apps-instance-sg"
  description = "Vulnerable apps EC2 host"
  vpc_id      = var.vpc_id

  ingress {
    description     = "SSH from bastion"
    from_port       = 22
    to_port         = 22
    protocol        = "tcp"
    security_groups = [var.bastion_sg_id]
  }

  ingress {
    description     = "App traffic from internal ALB"
    from_port       = 0
    to_port         = 65535
    protocol        = "tcp"
    security_groups = [aws_security_group.apps_alb.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, { Name = "${var.project_name}-apps-instance-sg" })
}

# ── EC2 app host ───────────────────────────────────────────────────────────────

resource "aws_instance" "apps" {
  ami                    = data.aws_ami.al2023.id
  instance_type          = var.instance_type
  subnet_id              = var.private_subnet_ids[0]
  vpc_security_group_ids = [aws_security_group.apps_instance.id]
  key_name               = var.key_name

  root_block_device {
    volume_size = 40
    volume_type = "gp3"
  }

  user_data = base64encode(<<-EOF
    #!/bin/bash
    dnf install -y docker git
    systemctl enable docker
    systemctl start docker
    usermod -aG docker ec2-user
    curl -fsSL "https://github.com/docker/compose/releases/latest/download/docker-compose-linux-x86_64" \
      -o /usr/local/bin/docker-compose
    chmod +x /usr/local/bin/docker-compose
  EOF
  )

  tags = merge(var.tags, {
    Name = "${var.project_name}-apps-host"
    Role = "apps"
  })
}

# ── Internal ALB ───────────────────────────────────────────────────────────────

resource "aws_lb" "apps" {
  name               = "${var.project_name}-apps-int-alb"
  internal           = true
  load_balancer_type = "application"
  security_groups    = [aws_security_group.apps_alb.id]
  subnets            = var.private_subnet_ids

  tags = merge(var.tags, { Name = "${var.project_name}-apps-int-alb" })
}

# ── Per-app target groups, listeners, and instance registrations ───────────────

locals {
  apps = {
    crapi     = { port = 8080, health_path = "/" }
    juiceshop = { port = 3000, health_path = "/" }
    vampi     = { port = 5000, health_path = "/" }
    dvga      = { port = 5013, health_path = "/" }
    pixi      = { port = 8888, health_path = "/" }
  }
}

resource "aws_lb_target_group" "apps" {
  for_each = local.apps

  name     = "${var.project_name}-${each.key}-tg"
  port     = each.value.port
  protocol = "HTTP"
  vpc_id   = var.vpc_id

  health_check {
    path                = each.value.health_path
    healthy_threshold   = 2
    unhealthy_threshold = 3
    interval            = 30
    matcher             = "200-404"
  }

  tags = var.tags
}

resource "aws_lb_listener" "apps" {
  for_each = local.apps

  load_balancer_arn = aws_lb.apps.arn
  port              = each.value.port
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.apps[each.key].arn
  }
}

resource "aws_lb_target_group_attachment" "apps" {
  for_each = local.apps

  target_group_arn = aws_lb_target_group.apps[each.key].arn
  target_id        = aws_instance.apps.id
  port             = each.value.port
}
