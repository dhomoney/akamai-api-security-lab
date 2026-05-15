resource "aws_ecr_repository" "kong" {
  name                 = "${var.project_name}/kong"
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = false
  }

  tags = merge(var.tags, { Name = "${var.project_name}-kong-ecr" })
}

resource "aws_ecr_repository" "nginx" {
  name                 = "${var.project_name}/nginx"
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = false
  }

  tags = merge(var.tags, { Name = "${var.project_name}-nginx-ecr" })
}

resource "aws_ecr_repository" "traffic" {
  name                 = "${var.project_name}/traffic"
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = false
  }

  tags = merge(var.tags, { Name = "${var.project_name}-traffic-ecr" })
}
