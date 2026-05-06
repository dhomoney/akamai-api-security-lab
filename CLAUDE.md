# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Purpose

Repeatable lab environment for testing and learning Akamai API Security (formerly Noname Security). Provisions AWS infrastructure via Terraform and configures it via Ansible. Kong OSS and NGINX OSS (OpenResty) run with Noname sensor plugins baked into custom ECR images; Anypoint Flex Gateway runs in connected mode with `registration.yaml` injected from AWS Secrets Manager. Flex Gateway is covered by the Noname **Sensor** (an ECS DaemonSet sniffing host NICs), not by the Mulesoft custom-policy path. All three traffic sources — `lab-kong`, `lab-nginx`, `lab-aws-ecs` — register with the engine end-to-end.

**Target environment**: AWS us-east-2, single VPC, ECS with EC2 launch type (t3.medium — t3.small is too small once the sensor lands on every host), local Terraform state.

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
    noname/                # Noname Sensor DaemonSet (host-network ECS task per cluster instance) + GCP Artifact Registry creds in Secrets Manager

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
    noname_integration/    # Registers Kong and NGINX as Noname traffic sources (the AWS ECS sensor source is created in the Noname UI before terraform apply)

docker/
  kong/Dockerfile          # FROM kong:latest + luarocks install of Noname Kong plugin; patches prevention.lua
  nginx/Dockerfile         # FROM openresty/openresty:bullseye + Noname Lua scripts; patches prevention.lua
  nginx/nginx.conf.template # nginx config with Noname Lua hooks; ${APPS_ALB_DNS} substituted at startup
  nginx/entrypoint.sh      # Runs envsubst, patches NN_SOURCE_KEY/NN_SOURCE_INDEX, starts OpenResty
  mulesoft/Dockerfile      # FROM mulesoft/flex-gateway:latest; uses COPY --chmod=755 (not RUN chmod); briefly USER root to mkdir+chown conf.d for the nonroot runtime user (uid 65532)
  mulesoft/entrypoint.sh   # Writes FLEX_REGISTRATION_YAML env var to /etc/mulesoft/flex-gateway/conf.d/registration.yaml, logs diagnostics to stderr, then exec's /init

integration-files/         # Drop Noname-provided .zip files here (gitignored)
  noname-security-kong-policy.zip
  noname-security-nginx-policy.zip
  noname-security-mulesoft-policy.zip

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

Each gateway (Kong, NGINX, MuleSoft) gets its own ALB. The Noname Sensor runs as a DaemonSet on the same ECS EC2 nodes (`network_mode = "host"`, `pid_mode = "host"`) and reports outbound to the Noname engine.

### ECS approach
EC2 launch type (not Fargate) so that Ansible can SSH into the underlying nodes for configuration. Nodes run Amazon Linux 2023 ECS-optimized AMI. The `ecs_cluster` module manages the ASG and ECS capacity provider; individual gateway modules deploy task definitions and services on top of that shared cluster.

### Kong (dbless mode)
Kong runs in declarative (`KONG_DATABASE=off`) mode. No Postgres. The Ansible `kong` role configures routes/services via the Admin API (port 8001) after deployment. The Admin API port is restricted to `admin_cidr` in the security group.

### Noname traffic source integrations
Three sources are registered in the tenant, each via a different mechanism:

- **`lab-kong`** (sourceType=`kong`) — Kong custom plugin baked into the Kong image; declarative config pushed by `make provision-plugins`.
- **`lab-nginx`** (sourceType=`nginx`) — Lua scripts baked into the OpenResty image; `sourceKey`/`sourceIndex` injected via ECS task env vars.
- **`lab-aws-ecs`** (sourceType=`aws-ecs`, internal type 201) — Noname Sensor DaemonSet on the ECS hosts (see "Noname Sensor (DaemonSet)" below). This is how Flex Gateway → Juice Shop traffic gets visibility.

The `noname_integration` Ansible role authenticates via `POST /auth/token` (service account `client_id`/`client_secret` → `accessToken` JWT), fetches the engine ID from `GET /api/v3/engines`, then registers Kong (`POST /api/v3/sources/kong`) and NGINX (`POST /api/v3/sources/nginx`). The `lab-aws-ecs` source is created in the Noname UI before `terraform apply` (see Sensor section); the deployment script there is the source of truth for the sensor env vars.

### Noname sensor plugins (Kong and NGINX)
Registering integrations is not enough — each gateway needs a sensor plugin that forwards API traffic to the Noname engine. The plugin is installed by baking it into a custom Docker image, not at runtime:

- **Kong**: `docker/kong/Dockerfile` installs the LuaRocks rock from the zip into `kong:latest`. The task definition adds `KONG_PLUGINS=bundled,nonamesecurity` when `noname_plugin_enabled=true`. The `ansible/plugins.yml` playbook fetches the correct `sourceKey`/`sourceIndex` from `GET /api/v3/sources` and pushes them via the Kong declarative config `/config` endpoint.
- **NGINX**: `docker/nginx/Dockerfile` builds on `openresty/openresty:bullseye` (which has LuaJIT + lua-nginx-module built in — standard `nginx:latest` does not). The Lua scripts are copied to `/usr/local/openresty/nginx/lua-scripts/`. The `nginx.conf.template` has the Noname hooks baked in; `entrypoint.sh` runs `envsubst` to substitute `${APPS_ALB_DNS}` at container startup.
- **prevention.lua type-guard patch**: BOTH Dockerfiles patch the Noname plugin's `prevention.lua` with a `if type(tbl) ~= "table" then return true end` guard before the `next(tbl)` call. The vendor plugin assumes `self._rules` is always a table, but when the engine returns a JSON-string error response, `cjson.decode` produces a Lua string and `next()` crashes with `bad argument #1 to 'next' (table expected, got string)`, returning 500 to the client. Kong patches `/usr/local/share/lua/5.1/kong/plugins/nonamesecurity/prevention.lua`; NGINX patches `/usr/local/openresty/nginx/lua-scripts/prevention.lua`.
- **Chicken-and-egg**: ECR repos must exist before images can be pushed. `make plugin-images` handles this: creates ECR repos via `terraform apply -target module.ecr`, builds and pushes images, then writes `terraform/plugin.auto.tfvars` (gitignored) with the ECR URIs and `noname_plugin_enabled=true`. A subsequent `make apply` picks up the new image references.
- **Source key mismatch**: The Kong zip ships with hardcoded `NN_SOURCE_KEY` values that differ from the registered integration's `sourceKey`. The `plugins.yml` playbook fetches the correct values dynamically from `GET /api/v3/sources`, making it generic for any team member's tenant.

### Noname Sensor (DaemonSet) — Flex Gateway coverage
Flex Gateway is not supported by the Mulesoft custom-policy path (see "Anypoint Flex Gateway" below for why). Coverage comes from the Noname Sensor instead, which runs as an ECS DaemonSet — one container per cluster EC2 instance — and sniffs each host's NIC for plaintext API traffic.

- **Task definition** (`terraform/modules/noname/main.tf`): `network_mode = "host"`, `pid_mode = "host"`, `user = "root"`, sized `256 cpu / 512 MiB`. ECS service is `scheduling_strategy = "DAEMON"` + `launch_type = "EC2"`.
- **Default capture**: BPF filter `tcp and not tcp port 443`. Linux capabilities added: `NET_ADMIN`, `NET_RAW`, `SYS_NICE`. No bind mounts.
- **eBPF mode** (gated on `noname_should_use_ebpf`, default `false`): adds `SYS_ADMIN`, `SYS_PTRACE` capabilities, bind-mounts `/` → `/host` and `/var/run/docker.sock`, and switches the entrypoint to `/sensor/ebpf_entry_point.sh`. Used to hook libssl in neighbouring containers for encrypted-traffic capture.
- **Container env vars**: `ENGINE_URL`, `SNIFF_SOURCE_TYPE` (default `201` for AWS ECS), `SNIFF_SOURCE_INDEX`, `SNIFF_SOURCE_KEY`, `SHOULD_USE_EBPF`, `LIBS_TO_HOOK`. Values come from the tenant's deployment script.
- **Image registry credentials**: the sensor image (`us-central1-docker.pkg.dev/noname-artifacts/nns-docker/noname-sensor:<tag>`) is in a private GCP Artifact Registry. The Noname-provided AWS ECS deployment script supplies a JSON `{"username":"_json_key_base64","password":"<base64 GCP SA key>"}`. Terraform stores it in Secrets Manager at `/${project_name}/noname/jfrog-credentials` and references it via `containerDefinitions[].repositoryCredentials.credentialsParameter`.
- **Provisioning order**: create the engine and the **AWS ECS** integration profile in the Noname UI (Settings → Integrations → Traffic Sources → Add Integration → AWS ECS) **before** running `terraform apply`. The "Create profile" step yields a CloudShell script with all values (`ENGINE_URL`, `SNIFF_SOURCE_KEY`, `SNIFF_SOURCE_INDEX`, image URI, JFrog JSON) baked in — copy them into `terraform.tfvars`. Without these set, the sensor task starts with empty source values and fails.

### Anypoint Flex Gateway (MuleSoft)
Flex Gateway runs in connected mode. The `registration.yaml` (generated via `docker run --entrypoint flexctl mulesoft/flex-gateway registration create ...`) is stored in AWS Secrets Manager at `/${project_name}/mulesoft/registration-yaml`. Terraform creates the secret with a placeholder value and a `lifecycle { ignore_changes = [secret_string] }` block so subsequent applies do not overwrite the real value. The ECS task injects it as `FLEX_REGISTRATION_YAML`; `docker/mulesoft/entrypoint.sh` writes it to `/etc/mulesoft/flex-gateway/conf.d/registration.yaml` and then `exec /init`. The task execution role has `secretsmanager:GetSecretValue` on that specific secret ARN.

**Wrapper image plumbing — preserve these or the gateway breaks:**
- The base image runs as non-root (uid 65532) and `/etc/mulesoft/flex-gateway/` is root-owned, so a plain `mkdir`/write inside the entrypoint fails with `Permission denied`. The Dockerfile briefly `USER root` to `mkdir -p /etc/mulesoft/flex-gateway/conf.d && chown -R 65532:0 /etc/mulesoft/flex-gateway/conf.d`, then switches back to `USER 65532` before copying the entrypoint.
- The actual gateway runtime is `/init` — a small script at the image root that exports `FLEX_CONFIG_DIR=/etc/mulesoft/flex-gateway/conf.d:/usr/local/share/mulesoft/flex-gateway/conf.d` (colon-separated list of directories the agent watches) and execs `/usr/local/bin/flex-agent`. Earlier attempts used `exec flexctl run`, which fails because `flexctl` is just a CLI tool with no `run` subcommand.
- The write target must be inside one of the `FLEX_CONFIG_DIR` paths or the agent's directory watcher won't pick it up. We use `conf.d/registration.yaml` (the first entry, also the writable one).
- The entrypoint logs the env-var byte count, the resulting file size and line count, and the first 3 lines to stderr — these show up in CloudWatch alongside the agent output and are the primary tool for debugging registration parsing.

**ECS service tuning:**
- `aws_ecs_service.mulesoft` sets `health_check_grace_period_seconds = 600`. In connected mode envoy has zero listeners until a proxy API is deployed from API Manager, so the gateway returns 502 on the ALB health check during startup. Without the 10-min grace window, ECS replaces the task before the agent has time to register with Anypoint and receive listener configuration.
- `aws_lb_target_group.mulesoft` health check uses `path = "/"`, `matcher = "200-499"`, `unhealthy_threshold = 5`. AWS rejects matchers above 499 (so we cannot accept the 502 directly), which is why the grace period is the load-bearing piece during startup.

To update `registration.yaml` without touching Terraform:
```bash
aws secretsmanager put-secret-value \
  --secret-id "/${project_name}/mulesoft/registration-yaml" \
  --secret-string "$(cat registration.yaml)" \
  --profile SA_Standard_Access-491489166083 --region us-east-2
```

### Secrets flow
- Terraform: sensitive values come from `terraform.tfvars` (gitignored). Flex Gateway `registration.yaml` lands in AWS Secrets Manager at `/${project_name}/mulesoft/registration-yaml` (too large for SSM — exceeds 8KB Advanced tier limit). The Noname Sensor's GCP Artifact Registry SA key (JSON) lands in Secrets Manager at `/${project_name}/noname/jfrog-credentials` and is consumed via `repositoryCredentials`. The sensor's `SNIFF_SOURCE_KEY` is passed straight into the task as a (sensitive) env var — no SSM/Secrets Manager indirection.
- Ansible: All credentials live in `ansible/vault.yml` (gitignored, AES256-encrypted). Decrypted at runtime using `~/.vault_pass`.

## Known TODOs / Incomplete Areas

- **HTTPS / TLS**: ALB listeners are HTTP only. Add ACM certificate + HTTPS listeners for any scenario requiring TLS-in-transit testing.
- **Cluster headroom**: three `t3.medium` hosts each running a sensor task plus 1–2 gateway/app tasks is reasonably packed. Bumping any task's memory (Kong, NGINX, Mulesoft, vulnerable apps) likely requires a bigger instance type or a placement-strategy change.

## Ansible Implementation Notes — Do Not Regress These

- `ansible.cfg` disables ControlMaster (`ControlMaster=no`) to avoid stale SSH socket errors when going through the bastion. `pipelining = True` keeps performance acceptable.
- The common play uses `serial: 1` to avoid overloading the bastion with parallel ProxyJump connections.
- The ECS AMI ships `curl-minimal` — do not install `curl` via DNF (conflict). Use `uri` module for HTTP tasks instead.
- The `pixi` vulnerable app uses `mccutchen/go-httpbin:latest` (the canonical 42crunch pixi image is not publicly available).
- Noname integration engine ID is fetched dynamically via `GET /api/v3/engines` — no vault variable needed for it.
- The `nginx` role runs on `localhost` and checks the NGINX ALB (not the ECS node directly); `nginx_alb_dns` is passed as an extra-var from Terraform output.
- No `version:` key in any Docker Compose files — it is obsolete in modern Docker and generates warnings.
- The `noname_integration` role does a `GET /api/v3/sources` first and only POSTs to register `lab-kong`/`lab-nginx` if the alias is not already present. Without this guard, every `make provision` run created a new duplicate source (the API does not return 409 on conflict — it just creates another).
- After pulling new crAPI images that change env-var shape (TLS/MongoDB/Postgres credential vars), the postgres and mongo volumes must be wiped once with `cd /opt/apps/crapi && sudo docker-compose down -v` on the apps host. The init env vars (`POSTGRES_PASSWORD`, `MONGO_INITDB_ROOT_*`) only apply to a fresh data dir; existing volumes keep the old credentials and break authentication from the application services.
- **Do not try the Mulesoft custom-policy path against Flex Gateway.** `noname-security-mulesoft-policy.zip` is packaged as a Mule 4 `mule-policy` (POM `<packaging>mule-policy</packaging>`, parent `mule-modules-parent`). API Manager will only apply it to APIs running on the Mule 4 Runtime; APIs running on Flex Gateway show "Not covered: there is no policy implementation for the runtime version where this API is running." Per Noname docs, Flex Gateway is supported via the **Noname Sensor** (the AWS ECS DaemonSet in `terraform/modules/noname/`), not the policy zip — running `install_mule.pyz` against a Flex Gateway proxy API is a dead end.
- Existing `t3.small` ECS hosts from earlier deploys do not pick up the `t3.medium` launch template automatically. Trigger an ASG instance refresh (or terminate the old hosts one at a time) so the new launch template takes effect. The sensor's 512 MiB will not schedule on the old t3.small instances alongside a gateway task.
