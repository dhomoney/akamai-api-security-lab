# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Purpose

Repeatable lab environment for testing and learning Akamai API Security (formerly Noname Security). Provisions AWS infrastructure via Terraform and configures it via Ansible. All three API gateways (Kong OSS, NGINX OSS, MuleSoft) run simultaneously and are integrated with a pre-provisioned Noname SaaS tenant.

**Target environment**: AWS us-east-2, single VPC, ECS with EC2 launch type (t3.small), local Terraform state.

## Common Commands

```bash
# First-time setup
make install-terraform   # installs Terraform to /usr/local/bin
make setup               # creates .venv, installs Ansible + Galaxy collections
make keys                # generates keys/lab_key (ED25519 SSH keypair)

# Copy and fill in secrets
cp terraform/terraform.tfvars.example terraform/terraform.tfvars
make vault-create        # creates and encrypts ansible/vault.yml from example

# Full deployment
make deploy              # terraform init → apply → ansible provision

# Individual steps
make init                # terraform init
make plan                # terraform plan
make apply               # terraform apply
make provision           # ansible-playbook site.yml

# Teardown
make destroy             # terraform destroy (prompts if -auto-approve removed)

# Linting
make lint                # runs both terraform and ansible linters
make lint-tf             # terraform fmt -check + validate + tflint
make lint-ansible        # ansible-lint

# Vault management
make vault-edit          # edit encrypted vault.yml
```

All `make` targets are self-documented: run `make` (no args) to list them.

The Ansible vault password file is expected at `~/.vault_pass`. The `AWS_PROFILE` environment variable controls which AWS CLI profile Ansible uses for dynamic inventory.

## Repository Structure

```
terraform/
  main.tf                  # Root module — wires all child modules together
  variables.tf / outputs.tf
  terraform.tfvars.example # Copy to terraform.tfvars and fill in admin_cidr
  modules/
    vpc/                   # VPC, public/private subnets, IGW, single NAT GW
    security_groups/       # ALB SG, ECS SG, Noname SG
    ecs_cluster/           # ECS cluster, EC2 launch template, ASG, capacity provider
    kong/                  # Kong OSS ECS task + ALB
    nginx/                 # NGINX OSS ECS task + ALB
    mulesoft/              # Mule Runtime ECS task + ALB (license TBD)
    noname/                # Noname sensor ECS task + SSM SecureString params

ansible/
  site.yml                 # Master playbook — runs all roles in order
  ansible.cfg              # Uses aws_ec2 dynamic inventory, SSH via keys/lab_key
  vault.yml.example        # Template for secrets — copy to vault.yml, encrypt
  requirements.yml         # Galaxy: amazon.aws, community.general, community.docker
  inventory/
    aws_ec2.yml            # Dynamic inventory filtered by tag Project=akamai-lab
  roles/
    common/                # OS updates, system limits for container workloads
    kong/                  # Kong Admin API: creates sample service + route
    nginx/                 # Pushes nginx.conf.j2 template
    mulesoft/              # Registers runtime with Anypoint Platform
    noname_integration/    # Registers Kong/NGINX/MuleSoft integrations via Noname API

.github/workflows/
  lint.yml                 # PR/push: terraform fmt+validate+tflint, ansible-lint
```

## Architecture

### Network flow
Internet → ALB (public subnets) → ECS EC2 nodes (private subnets) → containers

Each gateway (Kong, NGINX, MuleSoft) gets its own ALB. The Noname sensor runs as an ECS task in private subnets with outbound-only access to the Noname SaaS tenant.

### ECS approach
EC2 launch type (not Fargate) so that Ansible can SSH into the underlying nodes for configuration. Nodes run Amazon Linux 2023 ECS-optimized AMI. The `ecs_cluster` module manages the ASG and ECS capacity provider; individual gateway modules deploy task definitions and services on top of that shared cluster.

### Kong (dbless mode)
Kong runs in declarative (`KONG_DATABASE=off`) mode. No Postgres. The Ansible `kong` role configures routes/services via the Admin API (port 8001) after deployment. The Admin API port is restricted to `admin_cidr` in the security group.

### Noname sensor integration
The Noname sensor ECS task reads its tenant URL and API key from SSM SecureString parameters (populated by Terraform from `noname_sensor_image`, `noname_tenant_url`, `noname_api_key` variables). The `noname_integration` Ansible role then registers Kong, NGINX, and MuleSoft as integrations in the SaaS tenant via REST API calls from localhost. Integration API paths follow the Noname REST API — verify exact endpoints against your tenant's API docs as they may differ between Noname versions.

### Secrets flow
- Terraform: Noname credentials go into `terraform.tfvars` (gitignored) and land in SSM SecureString.
- Ansible: All credentials live in `ansible/vault.yml` (gitignored, AES256-encrypted). Decrypted at runtime using `~/.vault_pass`.

## Known TODOs / Incomplete Areas

- **MuleSoft image**: No official public Docker image exists. Build a custom image with the Mule Runtime and push to ECR. Update `var.mule_image` in `terraform.tfvars`.
- **Noname sensor image**: Obtain the connector image URI from your Akamai/Noname tenant deployment guide. Set `noname_sensor_image` in `terraform.tfvars`.
- **Noname API paths**: The `noname_integration` role uses assumed REST paths (`/api/v1/integrations`). Validate against actual Noname tenant API documentation.
- **MuleSoft Anypoint license**: Ansible `mulesoft` role's Anypoint registration step requires `vault_anypoint_client_id` and a valid license key in vault.
- **HTTPS / TLS**: ALB listeners are HTTP only. Add ACM certificate + HTTPS listeners for any scenario requiring TLS-in-transit testing.
