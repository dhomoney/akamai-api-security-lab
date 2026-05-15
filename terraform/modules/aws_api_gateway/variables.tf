variable "project_name" {
  type = string
}

variable "vpc_id" {
  type = string
}

variable "vpc_cidr" {
  description = "VPC CIDR block — used for NLB→apps instance SG ingress rule"
  type        = string
  default     = "10.0.0.0/16"
}

variable "private_subnet_ids" {
  description = "Private subnets for the internal NLB"
  type        = list(string)
}

variable "apps_instance_ip" {
  description = "Private IP of the apps EC2 instance — registered as NLB IP target for JuiceShop on port 3000"
  type        = string
}

variable "apps_instance_sg_id" {
  description = "Security group ID of the apps EC2 instance — receives port-3000 ingress rule for NLB passthrough"
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
