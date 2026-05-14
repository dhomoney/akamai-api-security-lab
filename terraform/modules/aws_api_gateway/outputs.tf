output "api_url" {
  description = "API Gateway invoke URL (HTTPS) — use as API_GW_URL in traffic scripts"
  value       = aws_apigatewayv2_api.main.api_endpoint
}

output "log_group_name" {
  description = "CloudWatch log group name receiving API Gateway access logs"
  value       = aws_cloudwatch_log_group.api_gw.name
}

output "log_group_arn" {
  description = "CloudWatch log group ARN"
  value       = aws_cloudwatch_log_group.api_gw.arn
}
