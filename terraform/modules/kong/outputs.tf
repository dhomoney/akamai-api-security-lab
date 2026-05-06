output "alb_dns_name" { value = aws_lb.kong.dns_name }
output "admin_url" { value = "http://${aws_lb.kong.dns_name}:8001" }
