variable "project_name"       { type = string }
variable "cluster_id"         { type = string }
variable "cluster_name"       { type = string }
variable "vpc_id"             { type = string }
variable "private_subnet_ids" { type = list(string) }
variable "public_subnet_ids"  { type = list(string) }
variable "task_sg_id"         { type = string }
variable "alb_sg_id"          { type = string }
variable "capacity_provider"  { type = string }
variable "mule_image" {
  description = "Flex Gateway wrapper image URI — set by 'make plugin-images' via plugin.auto.tfvars"
  type        = string
  default     = "mulesoft/flex-gateway:latest"
}
variable "registration_yaml_secret_arn" {
  description = "ARN of the Secrets Manager secret holding registration.yaml content"
  type        = string
}
variable "tags" {
  type    = map(string)
  default = {}
}
