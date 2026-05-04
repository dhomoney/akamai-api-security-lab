variable "project_name"       { type = string }
variable "cluster_id"         { type = string }
variable "cluster_name"       { type = string }
variable "vpc_id"             { type = string }
variable "private_subnet_ids" { type = list(string) }
variable "public_subnet_ids"  { type = list(string) }
variable "task_sg_id"         { type = string }
variable "alb_sg_id"          { type = string }
variable "capacity_provider"  { type = string }
variable "nginx_image" {
  type    = string
  default = "openresty/openresty:bullseye"
}
variable "apps_alb_dns" {
  type    = string
  default = ""
}
variable "noname_source_key" {
  type    = string
  default = ""
}
variable "noname_source_index" {
  type    = number
  default = 0
}
variable "tags" {
  type    = map(string)
  default = {}
}
