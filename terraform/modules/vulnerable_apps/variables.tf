variable "project_name"       { type = string }
variable "vpc_id"             { type = string }
variable "private_subnet_ids" { type = list(string) }
variable "ecs_sg_id"          { type = string }
variable "bastion_sg_id"      { type = string }
variable "key_name"           { type = string }

variable "instance_type" {
  type    = string
  default = "t3.medium"
}

variable "app_ports" {
  description = "Map of app name to host port — must match Docker Compose host port mappings"
  type        = map(number)
  default = {
    crapi     = 8080
    juiceshop = 3000
    vampi     = 5000
    dvga      = 5013
    pixi      = 8888
  }
}

variable "tags" {
  type    = map(string)
  default = {}
}
