variable "project_name" {
  type = string
}

variable "vpc_id" {
  type = string
}

variable "private_subnet_ids" {
  description = "Private subnets for the VPC Link ENIs"
  type        = list(string)
}

variable "juiceshop_alb_listener_arn" {
  description = "ARN of the apps internal ALB listener on port 3000 (JuiceShop)"
  type        = string
}

variable "apps_alb_sg_id" {
  description = "Security group ID of the apps internal ALB — receives an ingress rule from the VPC Link SG"
  type        = string
}

variable "kinesis_stream_arn" {
  description = "Kinesis stream ARN from the Noname Forwarder stack. Leave empty to skip CloudWatch subscription (add after running noname_connector)."
  type        = string
  default     = ""
}

variable "tags" {
  type    = map(string)
  default = {}
}
