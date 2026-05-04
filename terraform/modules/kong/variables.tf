variable "project_name"       { type = string }
variable "cluster_id"         { type = string }
variable "cluster_name"       { type = string }
variable "vpc_id"             { type = string }
variable "private_subnet_ids" { type = list(string) }
variable "public_subnet_ids"  { type = list(string) }
variable "task_sg_id"         { type = string }
variable "alb_sg_id"          { type = string }
variable "capacity_provider"  { type = string }
variable "kong_image" {
  type    = string
  default = "kong:latest"
}
variable "noname_plugin_enabled" {
  type    = bool
  default = false
}
variable "tags" {
  type    = map(string)
  default = {}
}
