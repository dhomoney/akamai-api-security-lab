terraform {
  required_version = ">= 1.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region  = var.aws_region
  profile = var.aws_profile
}

module "ecr" {
  source       = "./modules/ecr"
  project_name = var.project_name
  tags         = local.common_tags
}

module "bastion" {
  source = "./modules/bastion"

  project_name     = var.project_name
  vpc_id           = module.vpc.vpc_id
  public_subnet_id = module.vpc.public_subnet_ids[0]
  admin_cidr       = var.admin_cidr
  key_name         = aws_key_pair.lab.key_name
  tags             = local.common_tags
}

resource "aws_key_pair" "lab" {
  key_name = "${var.project_name}-key"

  # `terraform validate` in CI runs without keys/lab_key.pub on disk (the
  # keypair is generated locally by `make keys` before `make apply` and is
  # gitignored). A bare `file(...)` call would fail validate because the
  # file argument is a real file-read at parse time. fileexists() lets us
  # fall back to a stub when the key is absent — the stub is never used in
  # a real plan/apply because that codepath always runs after `make keys`.
  public_key = fileexists("${path.root}/../keys/lab_key.pub") ? file("${path.root}/../keys/lab_key.pub") : "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA ci-validate-stub"

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

  project_name  = var.project_name
  vpc_id        = module.vpc.vpc_id
  admin_cidr    = var.admin_cidr
  bastion_sg_id = module.bastion.sg_id
  tags          = local.common_tags
}

module "ecs_cluster" {
  source = "./modules/ecs_cluster"

  project_name       = var.project_name
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

  project_name          = var.project_name
  cluster_id            = module.ecs_cluster.cluster_id
  vpc_id                = module.vpc.vpc_id
  public_subnet_ids     = module.vpc.public_subnet_ids
  alb_sg_id             = module.security_groups.alb_sg_id
  capacity_provider     = module.ecs_cluster.capacity_provider_name
  kong_image            = var.kong_image
  noname_plugin_enabled = var.noname_plugin_enabled
  tags                  = local.common_tags
}

module "nginx" {
  source = "./modules/nginx"

  project_name        = var.project_name
  cluster_id          = module.ecs_cluster.cluster_id
  vpc_id              = module.vpc.vpc_id
  public_subnet_ids   = module.vpc.public_subnet_ids
  alb_sg_id           = module.security_groups.alb_sg_id
  capacity_provider   = module.ecs_cluster.capacity_provider_name
  nginx_image         = var.nginx_image
  apps_alb_dns        = module.vulnerable_apps.apps_alb_dns
  noname_source_key   = var.noname_nginx_source_key
  noname_source_index = var.noname_nginx_source_index
  tags                = local.common_tags
}

module "noname_connector" {
  source = "./modules/noname_connector"

  project_name      = var.project_name
  cfn_template_path = fileexists("${path.root}/../integration-files/noname-aws-connector-forwarder.yaml") ? "${path.root}/../integration-files/noname-aws-connector-forwarder.yaml" : "${path.root}/../integration-files/noname-aws-connector-forwarder.json"
  organization_id   = var.aws_org_id
  tags              = local.common_tags
}

module "aws_api_gateway" {
  source = "./modules/aws_api_gateway"

  project_name               = var.project_name
  vpc_id                     = module.vpc.vpc_id
  private_subnet_ids         = module.vpc.private_subnet_ids
  juiceshop_alb_listener_arn = module.vulnerable_apps.app_listener_arns["juiceshop"]
  apps_alb_sg_id             = module.vulnerable_apps.apps_alb_sg_id
  kinesis_stream_arn         = module.noname_connector.kinesis_stream_arn
  tags                       = local.common_tags
}

module "vulnerable_apps" {
  source = "./modules/vulnerable_apps"

  project_name       = var.project_name
  vpc_id             = module.vpc.vpc_id
  private_subnet_ids = module.vpc.private_subnet_ids
  ecs_sg_id          = module.security_groups.ecs_sg_id
  bastion_sg_id      = module.bastion.sg_id
  key_name           = aws_key_pair.lab.key_name
  instance_type      = var.instance_type
  tags               = local.common_tags
}

module "noname" {
  source = "./modules/noname"

  project_name = var.project_name
  cluster_id   = module.ecs_cluster.cluster_id
  aws_region   = var.aws_region

  noname_engine_url             = var.noname_engine_url
  noname_sniff_source_key       = var.noname_sniff_source_key
  noname_sniff_source_index     = var.noname_sniff_source_index
  noname_sniff_source_type      = var.noname_sniff_source_type
  noname_should_use_ebpf        = var.noname_should_use_ebpf
  noname_jfrog_credentials_json = var.noname_jfrog_credentials_json
  noname_sensor_image           = var.noname_sensor_image

  tags = local.common_tags
}

locals {
  common_tags = {
    Project     = var.project_name
    Environment = "lab"
    ManagedBy   = "terraform"
  }
}
