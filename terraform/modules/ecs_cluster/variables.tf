variable "project_name"       { type = string }
variable "vpc_id"             { type = string }
variable "private_subnet_ids" { type = list(string) }
variable "instance_type"      { type = string }
variable "key_name"           { type = string }
variable "ecs_sg_id"          { type = string }
variable "min_size" {
  type    = number
  default = 1
}
variable "max_size" {
  type    = number
  default = 3
}
variable "desired_capacity" {
  type    = number
  default = 2
}
variable "tags" {
  type    = map(string)
  default = {}
}
