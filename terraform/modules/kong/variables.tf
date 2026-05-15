variable "project_name" { type = string }
variable "cluster_id" { type = string }
variable "vpc_id" { type = string }
variable "public_subnet_ids" { type = list(string) }
variable "alb_sg_id" { type = string }
variable "capacity_provider" { type = string }
variable "kong_image" {
  type    = string
  default = "kong:latest"
}
variable "noname_plugin_enabled" {
  type    = bool
  default = false
}
variable "noname_engine_url" {
  description = "Noname engine URL for the Kong plugin declarative config"
  type        = string
  default     = ""
}
variable "noname_source_key" {
  description = "Noname sourceKey for the lab-kong traffic source"
  type        = string
  default     = ""
}
variable "noname_source_index" {
  description = "Noname sourceIndex for the lab-kong traffic source"
  type        = number
  default     = 1
}
variable "tags" {
  type    = map(string)
  default = {}
}
