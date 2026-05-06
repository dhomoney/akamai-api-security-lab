variable "project_name" { type = string }
variable "vpc_id" { type = string }
variable "public_subnet_id" { type = string }
variable "admin_cidr" { type = string }
variable "key_name" { type = string }
variable "tags" {
  type    = map(string)
  default = {}
}
