output "api_url" {
  description = "REST API Gateway invoke URL (HTTPS) — use as API_GW_URL in traffic scripts"
  value       = "https://${aws_api_gateway_rest_api.main.id}.execute-api.${data.aws_region.current.name}.amazonaws.com/${aws_api_gateway_stage.lab.stage_name}"
}

output "log_group_name" {
  description = "CloudWatch log group name receiving API Gateway access logs"
  value       = aws_cloudwatch_log_group.api_gw.name
}

output "log_group_arn" {
  description = "CloudWatch log group ARN"
  value       = aws_cloudwatch_log_group.api_gw.arn
}

output "execution_log_group_name" {
  description = "CloudWatch log group name for API Gateway execution logs (data tracing)"
  value       = aws_cloudwatch_log_group.api_gw_execution.name
}
