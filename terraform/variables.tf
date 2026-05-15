variable "project_name" {
  description = "Prefix applied to all resource names"
  type        = string
  default     = "akamai-lab"
}

variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "us-east-2"
}

variable "aws_profile" {
  description = "AWS CLI profile to use"
  type        = string
  default     = "default"
}

variable "vpc_cidr" {
  description = "CIDR block for the lab VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "availability_zones" {
  description = "AZs to deploy into (2 recommended for ALB)"
  type        = list(string)
  default     = ["us-east-2a", "us-east-2b"]
}

variable "admin_cidr" {
  description = "CIDR allowed to reach admin ports (SSH, Kong Admin API). Set to your IP/32."
  type        = string
}

variable "instance_type" {
  description = "EC2 instance type for ECS cluster nodes"
  type        = string
  default     = "t3.small"
}

variable "kong_image" {
  description = "Kong container image URI. Defaults to public kong:latest; set to ECR URI after 'make plugin-images'."
  type        = string
  default     = "kong:latest"
}

variable "nginx_image" {
  description = "NGINX container image URI. Defaults to public openresty image; set to ECR URI after 'make plugin-images'."
  type        = string
  default     = "openresty/openresty:bullseye"
}

variable "traffic_image" {
  description = "Locust traffic generator image URI. Defaults to public image; set to ECR URI after 'make traffic-aws-build'."
  type        = string
  default     = "locustio/locust:latest"
}

variable "noname_plugin_enabled" {
  description = "When true, adds KONG_PLUGINS=bundled,nonamesecurity to the Kong task definition."
  type        = bool
  default     = false
}

variable "aws_org_id" {
  description = "AWS Organization ID. Required by some Noname Forwarder CFN templates; leave empty for single-account deployments if the downloaded template permits it."
  type        = string
  default     = ""
}

variable "noname_nginx_source_key" {
  description = "Noname sourceKey for the NGINX integration. Written by 'make provision-plugins' to plugin.auto.tfvars."
  type        = string
  default     = ""
}

variable "noname_nginx_source_index" {
  description = "Noname sourceIndex for the NGINX integration. Written by 'make provision-plugins' to plugin.auto.tfvars."
  type        = number
  default     = 0
}

variable "noname_kong_source_key" {
  description = "Noname sourceKey for the Kong integration. Written by 'make provision-plugins' to plugin.auto.tfvars."
  type        = string
  default     = ""
}

variable "noname_kong_source_index" {
  description = "Noname sourceIndex for the Kong integration. Written by 'make provision-plugins' to plugin.auto.tfvars."
  type        = number
  default     = 1
}

# ── Noname AWS ECS sensor (DaemonSet) — values from your Noname tenant's
# Settings → Integrations → Traffic Sources → AWS ECS deployment script. ──

variable "noname_engine_url" {
  description = "Noname engine URL (e.g., https://<tenant>.nonamesec.com/engine)"
  type        = string
  default     = ""
}

variable "noname_sniff_source_key" {
  description = "Noname sensor SNIFF_SOURCE_KEY from the AWS ECS integration profile"
  type        = string
  sensitive   = true
  default     = ""
}

variable "noname_sniff_source_index" {
  description = "Noname sensor SNIFF_SOURCE_INDEX"
  type        = number
  default     = 1
}

variable "noname_sniff_source_type" {
  description = "Noname sensor SNIFF_SOURCE_TYPE. AWS ECS sensor = 201."
  type        = number
  default     = 201
}

variable "noname_should_use_ebpf" {
  description = "Enable eBPF for encrypted-traffic sniffing (extra Linux caps + host bind mounts)"
  type        = bool
  default     = false
}

variable "noname_jfrog_credentials_json" {
  description = "Docker registry credentials JSON ({\"username\":..., \"password\":...}) from the Noname deployment script"
  type        = string
  sensitive   = true
  default     = ""
}

variable "noname_sensor_image" {
  description = "Noname sensor image URI from the deployment script"
  type        = string
  default     = "us-central1-docker.pkg.dev/noname-artifacts/nns-docker/noname-sensor:3.3.54"
}
