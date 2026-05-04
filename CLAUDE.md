# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Purpose

Repeatable lab environment for testing and learning Akamai API Security (formerly Noname Security). Provisions AWS infrastructure via Terraform and configures it via Ansible. Kong OSS, NGINX OSS (OpenResty), and Anypoint Flex Gateway run with Noname sensor plugins baked into custom ECR images. Flex Gateway runs in connected mode; its `registration.yaml` is stored in AWS Secrets Manager and injected at container startup.

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

# Traffic generation (feeds Noname engine for behavioral learning)
make traffic-install     # install Locust into .venv (once after setup)
make traffic             # headless traffic — all 4 APIs, Ctrl+C to stop
make traffic-ui          # Locust web UI at http://localhost:8089
TRAFFIC_USERS=25 TRAFFIC_RATE=5 make traffic  # tune rate

# Noname sensor plugin installation (run once per lab, requires Docker + integration-files/*.zip)
make deploy-plugins      # full flow: ECR → build images → apply → provision → plugin config
# Or step by step:
make plugin-images       # create ECR repos, build+push images, write terraform/plugin.auto.tfvars
make apply               # re-apply Terraform so ECS tasks pick up the new images
make provision-plugins   # push Noname plugin config to Kong; verify NGINX health
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
    mulesoft/              # Anypoint Flex Gateway ECS task + ALB; registration.yaml from Secrets Manager
    noname/                # Noname sensor ECS task + SSM SecureString params

ansible/
  site.yml                 # Master playbook — runs all roles in order
  plugins.yml              # Standalone playbook — configures Noname plugin on Kong
  ansible.cfg              # Uses aws_ec2 dynamic inventory, SSH via keys/lab_key
  vault.yml.example        # Template for secrets — copy to vault.yml, encrypt
  requirements.yml         # Galaxy: amazon.aws, community.general, community.docker
  inventory/
    aws_ec2.yml            # Dynamic inventory filtered by tag Project=akamai-lab
  roles/
    common/                # OS updates, system limits for container workloads
    kong/                  # Kong Admin API: creates sample service + route
    nginx/                 # Verifies NGINX ALB is reachable from localhost
    mulesoft/              # Registers runtime with Anypoint Platform
    noname_integration/    # Registers Kong and NGINX as Noname traffic sources (MuleSoft pending — needs policy zip from Akamai)

docker/
  kong/Dockerfile          # FROM kong:latest + luarocks install of Noname Kong plugin
  nginx/Dockerfile         # FROM openresty/openresty:bullseye + Noname Lua scripts; patches prevention.lua
  nginx/nginx.conf.template # nginx config with Noname Lua hooks; ${APPS_ALB_DNS} substituted at startup
  nginx/entrypoint.sh      # Runs envsubst, patches NN_SOURCE_KEY/NN_SOURCE_INDEX, starts OpenResty
  mulesoft/Dockerfile      # FROM mulesoft/flex-gateway:latest; uses COPY --chmod=755 (not RUN chmod — image runs as non-root)
  mulesoft/entrypoint.sh   # Writes FLEX_REGISTRATION_YAML env var to registration.yaml, then runs flexctl

integration-files/         # Drop Noname-provided .zip files here (gitignored)
  noname-security-kong-policy.zip
  noname-security-nginx-policy.zip

.github/workflows/
  lint.yml                 # PR/push: terraform fmt+validate+tflint, ansible-lint

scripts/
  kong-tunnel.sh           # SSH tunnel to Kong Admin API via bastion
  traffic/
    locustfile.py          # Locust traffic generator — 4 FastHttpUser classes
    requirements.txt       # locust>=2.20.0
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
The Noname sensor ECS task reads its tenant URL and API key from SSM SecureString parameters (populated by Terraform from `noname_sensor_image`, `noname_tenant_url`, `noname_api_key` variables). The `noname_integration` Ansible role authenticates via `POST /auth/token` (service account `client_id`/`client_secret` → `accessToken` JWT), fetches the engine ID from `GET /api/v3/engines`, then registers Kong (`POST /api/v3/sources/kong`) and NGINX (`POST /api/v3/sources/nginx`) as traffic source integrations. All API calls run from localhost.

### Noname sensor plugins (Kong and NGINX)
Registering integrations is not enough — each gateway needs a sensor plugin that forwards API traffic to the Noname engine. The plugin is installed by baking it into a custom Docker image, not at runtime:

- **Kong**: `docker/kong/Dockerfile` installs the LuaRocks rock from the zip into `kong:latest`. The task definition adds `KONG_PLUGINS=bundled,nonamesecurity` when `noname_plugin_enabled=true`. The `ansible/plugins.yml` playbook fetches the correct `sourceKey`/`sourceIndex` from `GET /api/v3/sources` and pushes them via the Kong declarative config `/config` endpoint.
- **NGINX**: `docker/nginx/Dockerfile` builds on `openresty/openresty:bullseye` (which has LuaJIT + lua-nginx-module built in — standard `nginx:latest` does not). The Lua scripts are copied to `/usr/local/openresty/nginx/lua-scripts/`. The `nginx.conf.template` has the Noname hooks baked in; `entrypoint.sh` runs `envsubst` to substitute `${APPS_ALB_DNS}` at container startup.
- **Chicken-and-egg**: ECR repos must exist before images can be pushed. `make plugin-images` handles this: creates ECR repos via `terraform apply -target module.ecr`, builds and pushes images, then writes `terraform/plugin.auto.tfvars` (gitignored) with the ECR URIs and `noname_plugin_enabled=true`. A subsequent `make apply` picks up the new image references.
- **Source key mismatch**: The Kong zip ships with hardcoded `NN_SOURCE_KEY` values that differ from the registered integration's `sourceKey`. The `plugins.yml` playbook fetches the correct values dynamically from `GET /api/v3/sources`, making it generic for any team member's tenant.

### Anypoint Flex Gateway (MuleSoft)
Flex Gateway runs in connected mode. The `registration.yaml` (generated via `docker run --entrypoint flexctl mulesoft/flex-gateway registration create ...`) is stored in AWS Secrets Manager at `/${project_name}/mulesoft/registration-yaml`. Terraform creates the secret with a placeholder value and a `lifecycle { ignore_changes = [secret_string] }` block so subsequent applies do not overwrite the real value. The ECS task injects it as `FLEX_REGISTRATION_YAML`; `docker/mulesoft/entrypoint.sh` writes it to `/etc/mulesoft/flex-gateway/registration.yaml` and then runs `flexctl run`. The task execution role has `secretsmanager:GetSecretValue` on that specific secret ARN.

To update `registration.yaml` without touching Terraform:
```bash
aws secretsmanager put-secret-value \
  --secret-id "/${project_name}/mulesoft/registration-yaml" \
  --secret-string "$(cat registration.yaml)" \
  --profile SA_Standard_Access-491489166083 --region us-east-2
```

### Secrets flow
- Terraform: Noname credentials go into `terraform.tfvars` (gitignored) and land in SSM SecureString. Flex Gateway `registration.yaml` goes into AWS Secrets Manager (too large for SSM — exceeds 8KB Advanced tier limit).
- Ansible: All credentials live in `ansible/vault.yml` (gitignored, AES256-encrypted). Decrypted at runtime using `~/.vault_pass`.

## Known TODOs / Incomplete Areas

- **Flex Gateway Noname source**: Flex Gateway ECS task and image build are complete. Pending: (1) obtain MuleSoft Flex Gateway policy zip from Akamai support, (2) create proxy APIs in Anypoint API Manager, (3) add `POST /api/v3/sources/mulesoft` registration task to `ansible/roles/noname_integration/tasks/main.yml`.
- **Noname sensor image**: Obtain the connector image URI from your Akamai/Noname tenant deployment guide. Set `noname_sensor_image` in `terraform.tfvars`.
- **HTTPS / TLS**: ALB listeners are HTTP only. Add ACM certificate + HTTPS listeners for any scenario requiring TLS-in-transit testing.

## Ansible Implementation Notes — Do Not Regress These

- `ansible.cfg` disables ControlMaster (`ControlMaster=no`) to avoid stale SSH socket errors when going through the bastion. `pipelining = True` keeps performance acceptable.
- The common play uses `serial: 1` to avoid overloading the bastion with parallel ProxyJump connections.
- The ECS AMI ships `curl-minimal` — do not install `curl` via DNF (conflict). Use `uri` module for HTTP tasks instead.
- The `pixi` vulnerable app uses `mccutchen/go-httpbin:latest` (the canonical 42crunch pixi image is not publicly available).
- Noname integration engine ID is fetched dynamically via `GET /api/v3/engines` — no vault variable needed for it.
- The `nginx` role runs on `localhost` and checks the NGINX ALB (not the ECS node directly); `nginx_alb_dns` is passed as an extra-var from Terraform output.
- No `version:` key in any Docker Compose files — it is obsolete in modern Docker and generates warnings.
