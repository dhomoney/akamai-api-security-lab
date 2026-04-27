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

output "mulesoft_alb_dns" {
  description = "MuleSoft runtime ALB DNS name"
  value       = module.mulesoft.alb_dns_name
}

output "ecs_cluster_name" {
  description = "ECS cluster name"
  value       = module.ecs_cluster.cluster_name
}

output "ssh_key_name" {
  description = "AWS key pair name for SSH access"
  value       = aws_key_pair.lab.key_name
}
