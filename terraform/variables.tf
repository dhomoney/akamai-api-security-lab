variable "project_name" {
  description = "Prefix applied to all resource names"
  type        = string
  default     = "akamai-lab"
}

variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "us-east-2"
}

variable "aws_profile" {
  description = "AWS CLI profile to use"
  type        = string
  default     = "default"
}

variable "vpc_cidr" {
  description = "CIDR block for the lab VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "availability_zones" {
  description = "AZs to deploy into (2 recommended for ALB)"
  type        = list(string)
  default     = ["us-east-2a", "us-east-2b"]
}

variable "admin_cidr" {
  description = "CIDR allowed to reach admin ports (SSH, Kong Admin API). Set to your IP/32."
  type        = string
}

variable "instance_type" {
  description = "EC2 instance type for ECS cluster nodes"
  type        = string
  default     = "t3.small"
}

variable "kong_image" {
  description = "Kong container image URI. Defaults to public kong:latest; set to ECR URI after 'make plugin-images'."
  type        = string
  default     = "kong:latest"
}

variable "nginx_image" {
  description = "NGINX container image URI. Defaults to public openresty image; set to ECR URI after 'make plugin-images'."
  type        = string
  default     = "openresty/openresty:bullseye"
}

variable "noname_plugin_enabled" {
  description = "When true, adds KONG_PLUGINS=bundled,nonamesecurity to the Kong task definition."
  type        = bool
  default     = false
}

variable "mule_image" {
  description = "Flex Gateway wrapper image URI. Set by 'make plugin-images' via plugin.auto.tfvars."
  type        = string
  default     = "mulesoft/flex-gateway:latest"
}

variable "noname_nginx_source_key" {
  description = "Noname sourceKey for the NGINX integration. Written by 'make provision-plugins' to plugin.auto.tfvars."
  type        = string
  default     = ""
}

variable "noname_nginx_source_index" {
  description = "Noname sourceIndex for the NGINX integration. Written by 'make provision-plugins' to plugin.auto.tfvars."
  type        = number
  default     = 0
}
