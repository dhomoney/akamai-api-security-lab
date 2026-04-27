terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }
}

provider "aws" {
  region  = var.aws_region
  profile = var.aws_profile
}

resource "aws_key_pair" "lab" {
  key_name   = "${var.project_name}-key"
  public_key = file("${path.root}/../keys/lab_key.pub")

  tags = local.common_tags
}

module "vpc" {
  source = "./modules/vpc"

  project_name = var.project_name
  vpc_cidr     = var.vpc_cidr
  azs          = var.availability_zones
  tags         = local.common_tags
}

module "security_groups" {
  source = "./modules/security_groups"

  project_name = var.project_name
  vpc_id       = module.vpc.vpc_id
  admin_cidr   = var.admin_cidr
  tags         = local.common_tags
}

module "ecs_cluster" {
  source = "./modules/ecs_cluster"

  project_name       = var.project_name
  vpc_id             = module.vpc.vpc_id
  private_subnet_ids = module.vpc.private_subnet_ids
  instance_type      = var.instance_type
  key_name           = aws_key_pair.lab.key_name
  ecs_sg_id          = module.security_groups.ecs_sg_id
  min_size           = 1
  max_size           = 3
  desired_capacity   = 2
  tags               = local.common_tags
}

module "kong" {
  source = "./modules/kong"

  project_name       = var.project_name
  cluster_id         = module.ecs_cluster.cluster_id
  cluster_name       = module.ecs_cluster.cluster_name
  vpc_id             = module.vpc.vpc_id
  private_subnet_ids = module.vpc.private_subnet_ids
  public_subnet_ids  = module.vpc.public_subnet_ids
  task_sg_id         = module.security_groups.ecs_sg_id
  alb_sg_id          = module.security_groups.alb_sg_id
  capacity_provider  = module.ecs_cluster.capacity_provider_name
  tags               = local.common_tags
}

module "nginx" {
  source = "./modules/nginx"

  project_name       = var.project_name
  cluster_id         = module.ecs_cluster.cluster_id
  cluster_name       = module.ecs_cluster.cluster_name
  vpc_id             = module.vpc.vpc_id
  private_subnet_ids = module.vpc.private_subnet_ids
  public_subnet_ids  = module.vpc.public_subnet_ids
  task_sg_id         = module.security_groups.ecs_sg_id
  alb_sg_id          = module.security_groups.alb_sg_id
  capacity_provider  = module.ecs_cluster.capacity_provider_name
  tags               = local.common_tags
}

module "mulesoft" {
  source = "./modules/mulesoft"

  project_name       = var.project_name
  cluster_id         = module.ecs_cluster.cluster_id
  cluster_name       = module.ecs_cluster.cluster_name
  vpc_id             = module.vpc.vpc_id
  private_subnet_ids = module.vpc.private_subnet_ids
  public_subnet_ids  = module.vpc.public_subnet_ids
  task_sg_id         = module.security_groups.ecs_sg_id
  alb_sg_id          = module.security_groups.alb_sg_id
  capacity_provider  = module.ecs_cluster.capacity_provider_name
  tags               = local.common_tags
}

module "noname" {
  source = "./modules/noname"

  project_name       = var.project_name
  cluster_id         = module.ecs_cluster.cluster_id
  cluster_name       = module.ecs_cluster.cluster_name
  vpc_id             = module.vpc.vpc_id
  private_subnet_ids = module.vpc.private_subnet_ids
  task_sg_id         = module.security_groups.noname_sg_id
  capacity_provider  = module.ecs_cluster.capacity_provider_name
  kong_admin_url     = module.kong.admin_url
  nginx_status_url   = module.nginx.status_url
  mulesoft_api_url   = module.mulesoft.api_url
  tags               = local.common_tags
}

locals {
  common_tags = {
    Project     = var.project_name
    Environment = "lab"
    ManagedBy   = "terraform"
  }
}
