output "task_definition_arn" {
  description = "ARN of the Locust Fargate task definition"
  value       = aws_ecs_task_definition.traffic.arn
}

output "log_group_name" {
  description = "CloudWatch log group for traffic generator tasks"
  value       = aws_cloudwatch_log_group.traffic.name
}
