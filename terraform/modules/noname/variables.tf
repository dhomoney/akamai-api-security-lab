variable "project_name"        { type = string }
variable "cluster_id"          { type = string }
variable "cluster_name"        { type = string }
variable "vpc_id"              { type = string }
variable "private_subnet_ids"  { type = list(string) }
variable "task_sg_id"          { type = string }
variable "capacity_provider"   { type = string }
variable "kong_admin_url"      { type = string }
variable "nginx_status_url"    { type = string }
variable "mulesoft_api_url"    { type = string }
variable "tags"                { type = map(string); default = {} }

variable "noname_sensor_image" {
  description = "Noname sensor Docker image URI — obtain from your Akamai/Noname tenant deployment guide"
  type        = string
  default     = "REPLACE_WITH_NONAME_IMAGE"
}

variable "noname_tenant_url" {
  description = "Noname SaaS tenant URL (stored in SSM SecureString)"
  type        = string
  sensitive   = true
  default     = "REPLACE_WITH_TENANT_URL"
}

variable "noname_api_key" {
  description = "Noname API key for sensor authentication (stored in SSM SecureString)"
  type        = string
  sensitive   = true
  default     = "REPLACE_WITH_API_KEY"
}
