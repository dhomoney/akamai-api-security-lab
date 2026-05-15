output "apps_alb_dns" { value = aws_lb.apps.dns_name }
output "apps_instance_ip" { value = aws_instance.apps.private_ip }
output "apps_alb_sg_id" { value = aws_security_group.apps_alb.id }
output "apps_instance_sg_id" { value = aws_security_group.apps_instance.id }

output "app_urls" {
  description = "Internal URLs for each vulnerable app (accessible from gateways only)"
  value = {
    for app, cfg in local.apps :
    app => "http://${aws_lb.apps.dns_name}:${cfg.port}"
  }
}

output "app_listener_arns" {
  description = "ALB listener ARN per app (keyed by app name)"
  value = {
    for app, _ in local.apps :
    app => aws_lb_listener.apps[app].arn
  }
}
