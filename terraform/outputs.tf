output "vpc_id" {
  description = "Lab VPC ID"
  value       = module.vpc.vpc_id
}

output "kong_alb_dns" {
  description = "Kong proxy ALB DNS name"
  value       = module.kong.alb_dns_name
}

output "kong_admin_url" {
  description = "Kong Admin API URL (internal)"
  value       = module.kong.admin_url
}

output "nginx_alb_dns" {
  description = "NGINX ALB DNS name"
  value       = module.nginx.alb_dns_name
}

output "api_gateway_url" {
  description = "AWS API Gateway invoke URL (replaces Flex Gateway ALB)"
  value       = module.aws_api_gateway.api_url
}

output "ecs_cluster_name" {
  description = "ECS cluster name"
  value       = module.ecs_cluster.cluster_name
}

output "ssh_key_name" {
  description = "AWS key pair name for SSH access"
  value       = aws_key_pair.lab.key_name
}

output "bastion_public_ip" {
  description = "Bastion host public IP - use as ProxyJump for SSH to private nodes"
  value       = module.bastion.public_ip
}

output "apps_alb_dns" {
  description = "Internal ALB DNS for vulnerable apps (accessible from gateways only)"
  value       = module.vulnerable_apps.apps_alb_dns
}

output "app_urls" {
  description = "Internal URLs for each vulnerable app"
  value       = module.vulnerable_apps.app_urls
}

output "kong_ecr_uri" {
  description = "ECR repository URI for the Kong plugin image"
  value       = module.ecr.kong_uri
}

output "nginx_ecr_uri" {
  description = "ECR repository URI for the NGINX/OpenResty plugin image"
  value       = module.ecr.nginx_uri
}
