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
