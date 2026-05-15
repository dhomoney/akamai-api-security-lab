variable "project_name" { type = string }
variable "aws_region" { type = string }
variable "traffic_image" { type = string }
variable "tags" {
  type    = map(string)
  default = {}
}
