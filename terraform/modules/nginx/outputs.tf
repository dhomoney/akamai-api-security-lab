output "alb_dns_name" { value = aws_lb.nginx.dns_name }
output "status_url" { value = "http://${aws_lb.nginx.dns_name}/nginx_status" }
