variable "project_name" { type = string }
variable "vpc_id" { type = string }
variable "admin_cidr" { type = string }
variable "bastion_sg_id" { type = string }
variable "tags" {
  type    = map(string)
  default = {}
}
