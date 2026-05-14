output "kong_uri" {
  description = "ECR URI for the Kong plugin image"
  value       = aws_ecr_repository.kong.repository_url
}

output "nginx_uri" {
  description = "ECR URI for the NGINX/OpenResty plugin image"
  value       = aws_ecr_repository.nginx.repository_url
}
