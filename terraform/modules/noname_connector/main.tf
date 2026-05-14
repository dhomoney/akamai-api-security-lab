# Deploys the Noname AWS Connector (Manual/Forwarder mode).
# The CFN template is downloaded from the Noname UI:
#   Settings → Integrations → Traffic Sources → Add Integration → AWS Connector → Manual → download ZIP
# Place the template at integration-files/noname-aws-connector-forwarder.yaml (or .json).
# This module is a no-op until that file exists — run `terraform apply` again after placing the file.
#
# The template is uploaded to S3 because CFN inline template_body is capped at 51,200 bytes.

data "aws_region" "current" {}

locals {
  template_exists = fileexists(var.cfn_template_path)
  cfn_parameters  = var.organization_id != "" ? { OrganizationId = var.organization_id } : {}
}

resource "aws_s3_bucket" "cfn_templates" {
  count         = local.template_exists ? 1 : 0
  bucket        = "${var.project_name}-cfn-templates"
  force_destroy = true
  tags          = var.tags
}

resource "aws_s3_bucket_public_access_block" "cfn_templates" {
  count  = local.template_exists ? 1 : 0
  bucket = aws_s3_bucket.cfn_templates[0].id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_object" "forwarder_template" {
  count  = local.template_exists ? 1 : 0
  bucket = aws_s3_bucket.cfn_templates[0].id
  key    = "noname-aws-connector-forwarder.yaml"
  source = var.cfn_template_path
  etag   = filemd5(var.cfn_template_path)
}

resource "aws_cloudformation_stack" "noname_forwarder" {
  count = local.template_exists ? 1 : 0

  name         = "${var.project_name}-noname-connector"
  template_url = "https://${aws_s3_bucket.cfn_templates[0].bucket}.s3.${data.aws_region.current.name}.amazonaws.com/${aws_s3_object.forwarder_template[0].key}"
  capabilities = ["CAPABILITY_IAM", "CAPABILITY_NAMED_IAM", "CAPABILITY_AUTO_EXPAND"]
  parameters   = local.cfn_parameters

  depends_on = [aws_s3_object.forwarder_template]

  tags = var.tags
}
