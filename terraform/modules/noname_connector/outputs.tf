# The Noname Forwarder CFN stack outputs the Kinesis stream ARN used to receive
# CloudWatch log subscriptions from API Gateway. The output key name depends on
# the exact template Noname provides — adjust `KinesisStreamArn` if it differs.
output "kinesis_stream_arn" {
  description = "Kinesis stream ARN for CloudWatch → Noname log forwarding (empty when CFN template not yet deployed)"
  value       = local.template_exists ? aws_cloudformation_stack.noname_forwarder[0].outputs["KinesisStreamArn"] : ""
}
