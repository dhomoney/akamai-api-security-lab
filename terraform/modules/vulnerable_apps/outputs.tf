output "apps_alb_dns" { value = aws_lb.apps.dns_name }
output "apps_instance_ip" { value = aws_instance.apps.private_ip }

output "app_urls" {
  description = "Internal URLs for each vulnerable app (accessible from gateways only)"
  value = {
    for app, cfg in local.apps :
    app => "http://${aws_lb.apps.dns_name}:${cfg.port}"
  }
}
