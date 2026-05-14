variable "project_name" {
  type = string
}

variable "cfn_template_path" {
  description = "Path to the Noname Forwarder CloudFormation template JSON (download from Noname UI: Settings → Integrations → Traffic Sources → Add Integration → AWS Connector → Manual → download ZIP)"
  type        = string
}

variable "organization_id" {
  description = "AWS Organization ID. Required by some Noname Forwarder CFN templates; leave empty for single-account deployments if the template permits it."
  type        = string
  default     = ""
}

variable "tags" {
  type    = map(string)
  default = {}
}
