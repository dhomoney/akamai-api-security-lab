variable "project_name"      { type = string }
variable "cluster_id"        { type = string }
variable "cluster_name"      { type = string }
variable "aws_region"        { type = string }

variable "tags" {
  type    = map(string)
  default = {}
}

variable "noname_sensor_image" {
  description = "Noname sensor image URI from the Noname AWS ECS deployment script"
  type        = string
  default     = "us-central1-docker.pkg.dev/noname-artifacts/nns-docker/noname-sensor:3.3.54"
}

variable "noname_engine_url" {
  description = "Noname engine URL (e.g., https://<tenant>.nonamesec.com/engine) — from the deployment script"
  type        = string
}

variable "noname_sniff_source_key" {
  description = "Sensor SNIFF_SOURCE_KEY from the AWS ECS integration profile"
  type        = string
  sensitive   = true
}

variable "noname_sniff_source_index" {
  description = "Sensor SNIFF_SOURCE_INDEX from the AWS ECS integration profile"
  type        = number
  default     = 1
}

variable "noname_sniff_source_type" {
  description = "Sensor SNIFF_SOURCE_TYPE. Per the Noname-provided script for AWS ECS sensor = 201"
  type        = number
  default     = 201
}

variable "noname_should_use_ebpf" {
  description = "Enable eBPF for encrypted-traffic sniffing. Requires extra capabilities and host bind mounts."
  type        = bool
  default     = false
}

variable "noname_jfrog_credentials_json" {
  description = "Docker registry credentials JSON ({\"username\":..., \"password\":...}) from the Noname deployment script"
  type        = string
  sensitive   = true
}
