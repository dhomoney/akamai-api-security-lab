# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Purpose

Repeatable lab environment for testing and learning Akamai API Security (formerly Noname Security). Provisions AWS infrastructure via Terraform and configures it via Ansible. Kong OSS and NGINX OSS (OpenResty) run with Noname sensor plugins baked into custom ECR images; AWS API Gateway (REST API V1) proxies JuiceShop via an NLB-backed VPC Link and forwards both access logs and execution logs (with data tracing) through a Noname Forwarder CloudFormation stack (Kinesis + Lambda). All three traffic sources — `lab-kong`, `lab-nginx`, `lab-api-gateway` — register with the engine end-to-end.

**Target environment**: AWS us-east-2, single VPC, ECS with EC2 launch type (t3.medium — t3.small is too small once the sensor lands on every host), local Terraform state.

## Tooling — RTK (Rust Token Killer)

`rtk` is a token-optimised CLI proxy installed at `~/.local/bin/rtk` (verify with `rtk --version`). **Always prefix shell commands you run in this lab with `rtk`** — it has dedicated filters for the common ones and falls through transparently for anything else, so it is always safe to use. Token reduction is typically 60–90% on dev operations.

Use it for:

- **Git** — `rtk git status`, `rtk git log`, `rtk git diff`, `rtk git show`, `rtk git add`, `rtk git commit`, `rtk git push`. Works for every git subcommand including ones not explicitly listed.
- **AWS CLI** — `rtk aws ecs describe-services …`, `rtk aws elbv2 describe-target-health …`, `rtk aws logs tail …`. Compresses JSON / strips noise.
- **Docker / Kubernetes** — `rtk docker ps`, `rtk docker logs`, `rtk kubectl get`, `rtk kubectl logs`.
- **Network** — `rtk curl <url>` (auto-JSON detection), `rtk wget <url>`.
- **Search / files** — `rtk grep <pattern>`, `rtk find <pattern>`, `rtk read <file>`, `rtk ls <path>`.
- **GitHub** — `rtk gh pr view`, `rtk gh run list`, `rtk gh issue list`, `rtk gh api`.
- **Logs / errors / diffs** — `rtk log <file>` (deduplicated), `rtk err <cmd>` (errors-only), `rtk diff` (ultra-condensed).

Chained commands need the prefix on each one: `rtk git add . && rtk git commit -m "msg" && rtk git push`.

When you genuinely need raw, unfiltered output (e.g., piping AWS JSON into `python3 -c "json.load(sys.stdin)…"`, or capturing exact byte-for-byte output for diff'ing), use `rtk proxy <command>` to bypass filtering. Filtered output is not always valid JSON.

Meta: `rtk gain` shows token savings, `rtk discover` analyses Claude Code history for missed opportunities, `rtk init --global` regenerates the global rules block.

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
make traffic             # headless baseline traffic — all 5 apps, Ctrl+C to stop
make traffic-ui          # Locust web UI at http://localhost:8089
TRAFFIC_USERS=25 TRAFFIC_RATE=5 make traffic                              # tune concurrency
# Identity-pool tunables. Defaults USER_POOL_SIZE=2000 / IDENTITY_ROTATION_INTERVAL=5,
# per-class seed VAMPI=200 / CRAPI=400 / JUICESHOP=200 — sized so each pool reaches
# USER_POOL_SIZE within ~8 min at TRAFFIC_USERS=50. CRAPI is highest because it has
# the fewest spawned instances (weight=1 vs 2 for VAmPI/JuiceShop) and slow signup.
USER_POOL_SEED_PER_INSTANCE_VAMPI=200 USER_POOL_SEED_PER_INSTANCE_CRAPI=400 USER_POOL_SEED_PER_INSTANCE_JUICESHOP=200 make traffic

# OWASP API Top 10 attack generator (populates the Noname Runtime tab)
make traffic-owasp       # headless attack run across all 5 apps
make traffic-owasp-ui    # Locust web UI for the attack file
ATTACK_USERS=20 ATTACK_RATE=4 make traffic-owasp  # tune rate (defaults 10/2)

# AWS Fargate traffic (platform-independent; works on Windows without WSL; genuine IP diversity)
make apply-ecr           # create ECR repos first (if not already done)
make traffic-aws-build   # build+push Locust image to ECR; write traffic.auto.tfvars; update Fargate task def
make traffic-aws         # launch TRAFFIC_AWS_TASKS (default 10) Fargate tasks for baseline traffic
make traffic-aws-logs    # tail CloudWatch logs from running Fargate tasks (Ctrl+C to stop)
make traffic-aws-stop    # stop all running Fargate traffic tasks
make traffic-owasp-aws   # launch ATTACK_AWS_TASKS (default 5) Fargate tasks for OWASP attacks
TRAFFIC_AWS_TASKS=20 TRAFFIC_AWS_USERS=10 make traffic-aws   # tune task count and users per task

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
    noname_connector/      # Noname Forwarder CFN stack (Kinesis + Lambda); uploads template to S3; exposes kinesis_stream_arn
    aws_api_gateway/       # REST API (V1) + NLB-backed VPC Link; access + execution log groups; CW→Kinesis subscription filters (both groups)
    noname/                # Noname Sensor DaemonSet (host-network ECS task per cluster instance) + GCP Artifact Registry creds in Secrets Manager
    traffic_generator/     # Fargate task definition for Locust; IAM exec role + CloudWatch log group; no ECS service (tasks launched ad-hoc via 'make traffic-aws')

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
    noname_integration/    # Registers Kong, NGINX, and AWS API Gateway connector as Noname traffic sources

docker/
  kong/Dockerfile          # FROM kong:latest + luarocks install of Noname Kong plugin; patches prevention.lua
  nginx/Dockerfile         # FROM openresty/openresty:bullseye + Noname Lua scripts; patches prevention.lua
  nginx/nginx.conf.template # nginx config with Noname Lua hooks; ${APPS_ALB_DNS} substituted at startup; resolver-based runtime DNS (variable proxy_pass + per-location rewrite, no upstream{} blocks) so ALB IP rotation does not cause 502s
  nginx/entrypoint.sh      # Runs envsubst, patches NN_SOURCE_KEY/NN_SOURCE_INDEX, starts OpenResty
  traffic/Dockerfile       # FROM python:3.12-slim + Locust; copies locustfile.py + attackfile.py; ENTRYPOINT python -m locust; CMD overridden at task launch via ECS container override

integration-files/         # Drop Noname-provided files here (gitignored)
  noname-security-kong-policy.zip
  noname-security-nginx-policy.zip
  noname-aws-connector-forwarder.yaml  # Noname Forwarder CFN template — download from Settings → Integrations → AWS Connector → Manual

.github/workflows/
  lint.yml                 # PR/push: terraform fmt+validate+tflint, ansible-lint

scripts/
  kong-tunnel.sh           # SSH tunnel to Kong Admin API via bastion
  traffic/
    locustfile.py          # Locust baseline traffic generator — one FastHttpUser class per app; VAmPI/CrAPI/JuiceShop share a class-level identity pool (target USER_POOL_SIZE authenticated users, rotated every IDENTITY_ROTATION_INTERVAL tasks)
    attackfile.py          # Locust OWASP API Top 10 (2023) attack generator — runs in parallel as a separate locustfile
    requirements.txt       # locust>=2.20.0
```

## Architecture

### Network flow
Internet → ALB or API Gateway (public) → ECS EC2 nodes or VPC Link (private subnets) → containers

Kong and NGINX each have their own public ALB. JuiceShop is reached via AWS API Gateway (REST API V1, `lab` stage) → VPC Link → internal NLB → apps EC2 instance on port 3000. The Noname Sensor runs as a DaemonSet on the ECS EC2 nodes (`network_mode = "host"`, `pid_mode = "host"`) and reports outbound to the Noname engine. API Gateway access logs AND execution logs (with data tracing) flow to CloudWatch → Kinesis stream (Noname Forwarder stack) → Noname engine.

### ECS approach
EC2 launch type (not Fargate) so that Ansible can SSH into the underlying nodes for configuration. Nodes run Amazon Linux 2023 ECS-optimized AMI. The `ecs_cluster` module manages the ASG and ECS capacity provider; individual gateway modules deploy task definitions and services on top of that shared cluster.

### Kong (dbless mode)
Kong runs in declarative (`KONG_DATABASE=off`) mode. No Postgres. The Ansible `kong` role configures routes/services via the Admin API (port 8001) after deployment. The Admin API port is restricted to `admin_cidr` in the security group.

### Noname traffic source integrations
Three sources are registered in the tenant, each via a different mechanism:

- **`lab-kong`** (sourceType=`kong`) — Kong custom plugin baked into the Kong image; declarative config pushed by `make provision-plugins`.
- **`lab-nginx`** (sourceType=`nginx`) — Lua scripts baked into the OpenResty image; `sourceKey`/`sourceIndex` injected via ECS task env vars.
- **`lab-api-gateway`** (type=`CONNECTOR`, integrationMethod=`MANUAL`) — Noname AWS Connector (Forwarder mode). API Gateway access logs flow via CloudWatch → Kinesis stream → Noname Forwarder Lambda → engine. Registered via `POST /api/v3/connectors/1`.

The `noname_integration` Ansible role authenticates via `POST /auth/token` (service account `client_id`/`client_secret` → `accessToken` JWT), fetches the engine ID from `GET /api/v3/engines`, fetches existing sources/connectors via `GET /api/v3/sources`, then registers Kong (`POST /api/v3/sources/kong`), NGINX (`POST /api/v3/sources/nginx`), and the AWS API Gateway connector (`POST /api/v3/connectors/1`) — all guarded by alias-existence checks to prevent duplicates. Note: `GET /api/v3/connectors` returns HTML (SPA page), not a JSON list; connectors appear in `GET /api/v3/sources` with `"type": "CONNECTOR"`. Deletion uses `DELETE /api/v3/connectors/{id}` (not the sources endpoint).

### Noname sensor plugins (Kong and NGINX)
Registering integrations is not enough — each gateway needs a sensor plugin that forwards API traffic to the Noname engine. The plugin is installed by baking it into a custom Docker image, not at runtime:

- **Kong**: `docker/kong/Dockerfile` installs the LuaRocks rock from the zip into `kong:latest`. The task definition adds `KONG_PLUGINS=bundled,nonamesecurity` when `noname_plugin_enabled=true`. The `ansible/plugins.yml` playbook fetches the correct `sourceKey`/`sourceIndex` from `GET /api/v3/sources` and pushes them via the Kong declarative config `/config` endpoint.
- **NGINX**: `docker/nginx/Dockerfile` builds on `openresty/openresty:bullseye` (which has LuaJIT + lua-nginx-module built in — standard `nginx:latest` does not). The Lua scripts are copied to `/usr/local/openresty/nginx/lua-scripts/`. The `nginx.conf.template` has the Noname hooks baked in; `entrypoint.sh` runs `envsubst` to substitute `${APPS_ALB_DNS}` and `${DNS_RESOLVER}` at container startup. The config uses `resolver ${DNS_RESOLVER} valid=10s ipv6=off;` plus `proxy_pass http://$apps_alb:port` (variable in the URL) so NGINX re-resolves the apps ALB hostname every 10 s — without this, AWS rotating an ALB node IP would silently break every `/vampi/*` and `/dvga/*` request until a redeploy. Each location also has an explicit `rewrite ^/<prefix>/(.*)$ /$1 break;` because variable-based `proxy_pass` does not auto-strip the location prefix the way a static `upstream` + `proxy_pass http://up/` does.
- **prevention.lua type-guard patch**: BOTH Dockerfiles patch the Noname plugin's `prevention.lua` with a `if type(tbl) ~= "table" then return true end` guard before the `next(tbl)` call. The vendor plugin assumes `self._rules` is always a table, but when the engine returns a JSON-string error response, `cjson.decode` produces a Lua string and `next()` crashes with `bad argument #1 to 'next' (table expected, got string)`, returning 500 to the client. Kong patches `/usr/local/share/lua/5.1/kong/plugins/nonamesecurity/prevention.lua`; NGINX patches `/usr/local/openresty/nginx/lua-scripts/prevention.lua`.
- **Chicken-and-egg**: ECR repos must exist before images can be pushed. `make plugin-images` handles this: creates ECR repos via `terraform apply -target module.ecr`, builds and pushes images, then writes `terraform/plugin.auto.tfvars` (gitignored) with the ECR URIs and `noname_plugin_enabled=true`. A subsequent `make apply` picks up the new image references.
- **Source key mismatch**: The Kong zip ships with hardcoded `NN_SOURCE_KEY` values that differ from the registered integration's `sourceKey`. The `plugins.yml` playbook fetches the correct values dynamically from `GET /api/v3/sources`, making it generic for any team member's tenant.

### Noname Sensor (DaemonSet)
The Noname Sensor runs as an ECS DaemonSet — one container per cluster EC2 instance — and sniffs each host's NIC for plaintext API traffic, giving the engine visibility into Kong and NGINX traffic at the host level.

- **Task definition** (`terraform/modules/noname/main.tf`): `network_mode = "host"`, `pid_mode = "host"`, `user = "root"`, sized `256 cpu / 512 MiB`. ECS service is `scheduling_strategy = "DAEMON"` + `launch_type = "EC2"`.
- **Default capture**: BPF filter `tcp and not tcp port 443`. Linux capabilities added: `NET_ADMIN`, `NET_RAW`, `SYS_NICE`. No bind mounts.
- **eBPF mode** (gated on `noname_should_use_ebpf`, default `false`): adds `SYS_ADMIN`, `SYS_PTRACE` capabilities, bind-mounts `/` → `/host` and `/var/run/docker.sock`, and switches the entrypoint to `/sensor/ebpf_entry_point.sh`. Used to hook libssl in neighbouring containers for encrypted-traffic capture.
- **Container env vars**: `ENGINE_URL`, `SNIFF_SOURCE_TYPE` (default `201` for AWS ECS), `SNIFF_SOURCE_INDEX`, `SNIFF_SOURCE_KEY`, `SHOULD_USE_EBPF`, `LIBS_TO_HOOK`. Values come from the tenant's deployment script.
- **Image registry credentials**: the sensor image (`us-central1-docker.pkg.dev/noname-artifacts/nns-docker/noname-sensor:<tag>`) is in a private GCP Artifact Registry. The Noname-provided AWS ECS deployment script supplies a JSON `{"username":"_json_key_base64","password":"<base64 GCP SA key>"}`. Terraform stores it in Secrets Manager at `/${project_name}/noname/jfrog-credentials` and references it via `containerDefinitions[].repositoryCredentials.credentialsParameter`.
- **Provisioning order**: create the engine and the **AWS ECS** integration profile in the Noname UI (Settings → Integrations → Traffic Sources → Add Integration → AWS ECS) **before** running `terraform apply`. The "Create profile" step yields a CloudShell script with all values (`ENGINE_URL`, `SNIFF_SOURCE_KEY`, `SNIFF_SOURCE_INDEX`, image URI, JFrog JSON) baked in — copy them into `terraform.tfvars`. Without these set, the sensor task starts with empty source values and fails.

### AWS API Gateway (JuiceShop)
JuiceShop traffic flows through an AWS API Gateway REST API (V1). The module is in `terraform/modules/aws_api_gateway/`. **HTTP API (V2) is NOT supported by the Noname Manual/Forwarder connector** — only REST API V1 produces execution logs with data tracing, which the Forwarder Lambda requires to form complete packet pairs.

- **NLB**: an internal Network Load Balancer in private subnets, with an IP target group pointing at the apps EC2 instance on port 3000. REST API V1 VPC Links require an NLB (not an ALB). Port 3000 ingress from the VPC CIDR is added to the apps instance SG to allow NLB passthrough traffic.
- **VPC Link**: `aws_api_gateway_vpc_link` targeting the NLB ARN.
- **Route**: `ANY /shop/{proxy+}` → `HTTP_PROXY` integration via VPC Link to `http://{nlb_dns}/{proxy}`. The `integration.request.path.proxy = method.request.path.proxy` parameter strips the `/shop/` prefix before forwarding to JuiceShop.
- **Stage**: `lab`. Access logs go to `/aws/apigateway/${project_name}` (7-day retention) in the Noname `[NONAME]…[NONAME]` format. Execution logging (level=INFO) and data tracing are enabled via `aws_api_gateway_method_settings` (`method_path = "*/*"`) — this produces the second log stream the Forwarder Lambda needs.
- **Execution log group**: pre-created in Terraform as `API-Gateway-Execution-Logs_{rest_api_id}/lab` so retention and subscription can be managed. AWS writes execution logs to this auto-named group when logging is enabled.
- **CloudWatch → Kinesis**: TWO `aws_cloudwatch_log_subscription_filter` resources — one for the access log group, one for the execution log group. Both route to the Kinesis stream from the Noname Forwarder CFN stack. The Forwarder Lambda pairs them by `requestId` via DynamoDB to form complete API transactions (`isComplete: True`). IAM role needs `kinesis:PutRecord` + `kms:GenerateDataKey` + `kms:Decrypt` (Forwarder stack encrypts the stream by default).
- **Account-level IAM**: `aws_api_gateway_account` sets the CloudWatch logs delivery role (account-level singleton; safe to have in one Terraform state per account).
- **Noname Forwarder stack** (`terraform/modules/noname_connector/`): uploads the CFN template to S3 (the 67 KB template exceeds the 51,200-byte CloudFormation inline body limit) and deploys it as `${project_name}-noname-connector`. The Outputs section must include `KinesisStreamArn` (appended to the template after download — the Noname-provided template has no Outputs). Capabilities: `CAPABILITY_IAM`, `CAPABILITY_NAMED_IAM`, `CAPABILITY_AUTO_EXPAND` (required for SAM transforms). Parameter: `OrganizationId` from AWS Organizations.
- **Pre-deploy step**: download the Forwarder CFN template from the Noname UI (Settings → Integrations → Traffic Sources → Add Integration → AWS Connector → Manual → download ZIP), extract the YAML, and place it at `integration-files/noname-aws-connector-forwarder.yaml`. The module is a no-op until the file exists. After placing it, append the Outputs section if the downloaded template lacks one.
- **NonameSender DynamoDB table name drift (recurring gotcha)**: `NonameCodeDeployer` runs every 10 min and auto-updates `NonameSender` to the latest code version from the Noname engine. Code version `v3.64.1` changed the expected DynamoDB table name from `NonamePacketPairByRequestId-{stack-suffix}` (suffixed, created by CFN) to `NonamePacketPairByRequestId` (no suffix, pre-existing in the account). The CFN stack's inline IAM policy only covers the suffixed ARN, so the Lambda starts failing `dynamodb:GetItem` — connector goes PENDING/offline. Fix: add `arn:aws:dynamodb:{region}:{account}:table/NonamePacketPairByRequestId` and its `/*` items ARN to the `SenderManagement-*` inline policy on the `NonameSenderFunctionExecu-*` role via `aws iam put-role-policy`. The unsuffixed table already exists in the account (created by a prior Noname deployment); do NOT create a new one. Symptom: `NonameSender` logs show `ERROR: not authorized to perform: dynamodb:GetItem on resource: .../table/NonamePacketPairByRequestId`.
- **CFN template ID mismatch (critical gotcha)**: the downloaded template bakes in placeholder connector IDs at download time, *before* the real connector ID is assigned. After deploying the stack and verifying the connector exists in Noname via `GET /api/v3/sources`, update the template's `Mappings.Variables.Connector` section: set `ID` to the real connector `id` (e.g. `3d891fe4-...`), and update `SourcesConfiguration.aws-api-gateway` to use the correct `id`, `index`, and `key` from the same API response. Without this fix, `NonameSender` uses a non-existent connector ID → 404 from the engine → connector stays `PENDING` indefinitely. After patching the template, run `terraform apply` to push the corrected values into the CloudFormation stack. The `NonameCodeDeployer` Lambda also holds the connector ID in its `CONNECTOR_ID` env var — update it via `aws lambda update-function-configuration` if the stack redeploy doesn't pick it up automatically (the CodeDeployer runs every 10 min via EventBridge and will otherwise log 404 errors when reporting connector status).

### Secrets flow
- Terraform: sensitive values come from `terraform.tfvars` (gitignored). The Noname Sensor's GCP Artifact Registry SA key (JSON) lands in Secrets Manager at `/${project_name}/noname/jfrog-credentials` and is consumed via `repositoryCredentials`. The sensor's `SNIFF_SOURCE_KEY` is passed straight into the task as a (sensitive) env var — no SSM/Secrets Manager indirection.
- Ansible: All credentials live in `ansible/vault.yml` (gitignored, AES256-encrypted). Decrypted at runtime using `~/.vault_pass`.

### Traffic generation — two-phase workflow
Baseline and attack traffic are deliberately separate locustfiles. Run them as distinct phases of a demo, not concurrently — mixing them poisons the behavioural baseline.

**AWS Fargate execution mode.** `make traffic-aws` and `make traffic-owasp-aws` run Locust inside Docker on ECS Fargate instead of locally, making traffic generation platform-independent (no local Python/venv; works on Windows without WSL) and enabling it to run unattended. The flow:
1. `make apply-ecr` — creates the traffic ECR repo (part of the ECR module, run once before first build)
2. `make traffic-aws-build` — builds `docker/traffic/Dockerfile`, pushes to ECR, writes `terraform/traffic.auto.tfvars` with the ECR URI, runs `terraform apply -target module.traffic_generator` to update the Fargate task definition
3. `make traffic-aws` — launches `TRAFFIC_AWS_TASKS` (default 10) independent Fargate tasks via `aws ecs run-task`, each running `TRAFFIC_AWS_USERS` (default 5) Locust users; total traffic = tasks × users
4. `make traffic-aws-logs` — tails `/ecs/<project>/traffic` CloudWatch log group
5. `make traffic-aws-stop` — stops all tasks in the `<project>-traffic` family

Each Fargate task gets its own ENI with a unique private IP. The Kong and NGINX ALBs are internet-facing but accessible from within the VPC; Fargate tasks in private subnets reach them via NAT. The XFF injection (`N_CONSUMER_IPS=10` default) still applies — each Locust user instance within a task picks a distinct fake source IP from `10.20.x.y`, so Noname sees diverse consumer IPs even when multiple tasks share the same NAT gateway egress IP. The task definition is in `terraform/modules/traffic_generator/` (512 CPU / 1024 MiB, Fargate, `awsvpc` networking, 3-day log retention). No ECS service is created — tasks are ephemeral, launched on demand.

1. **Baseline (`scripts/traffic/locustfile.py`)** — `make traffic` exercises the five vulnerable apps with realistic happy-path requests so the Noname engine can learn normal patterns per source. Let it run ~30 minutes for the first build before declaring the baseline trained.
2. **Attacks (`scripts/traffic/attackfile.py`)** — `make traffic-owasp` then fires OWASP API Top 10 (2023) attacks against the same gateways. Noname flags these as anomalies against the trained baseline and surfaces them in the Runtime tab as detection events.

**Consumer IP pooling (both files).** Each Locust worker instance picks one fake source IP from a pool (default 10 IPs, configurable via `N_CONSUMER_IPS=<n>`) and injects it as `X-Forwarded-For` on every request via the geventhttpclient session's `default_headers`. The public Kong and NGINX ALBs append the runner's real IP after the injected value; Noname reads the first (leftmost) XFF entry as the original consumer IP, so the engine sees 10+ distinct source IPs across all workers. API Gateway is unaffected (`$context.identity.sourceIp` is the actual TCP source, not XFF); JuiceShop source-IP diversity relies on user-identity tokens only. The generated pool occupies `10.20.x.y` (RFC 1918, unused in the lab VPC).

**Identity pooling (baseline only).** Noname's behavioural engine learns per-source baselines from the diversity of authenticated users it sees, not from raw request volume — a run with 50 concurrent locust users and 50 distinct tokens is far short of what the engine needs to converge. To raise diversity without flooding the gateways with 2000 concurrent users, each authenticated User class (`VAmPIUser`, `CrAPIUser`, `JuiceShopUser`) maintains a class-level shared `_identity_pool`. On startup each instance registers up to `USER_POOL_SEED_PER_INSTANCE` (default 50) fresh identities and appends them to the pool, capped at `USER_POOL_SIZE` (default 2000). Every `IDENTITY_ROTATION_INTERVAL` (default 5) tasks an instance rotates: if the pool is below target, register a new identity and use it; otherwise pick a random existing pool entry. So the pool grows during the run AND identities get reused once full. `HttpBinUser` and `DVGAUser` are stateless and unchanged. `JuiceShopUser` does register + login (token at `$.authentication.token`) and routes `post_feedback` and `get_basket` through `self.auth`; the rest stay anonymous on purpose to mimic shopper-pre-login traffic. Side effect: the apps' user tables accumulate ~2000 records per service over a long run — only `make destroy` resets them.

The attack file covers 9 of the 10 OWASP API 2023 categories: API1 BOLA, API2 Broken Auth, API3 BOPLA / mass assignment, API4 Unrestricted Resource Consumption, API5 BFLA, API6 Sensitive Business Flows (coupon abuse + rapid order in JuiceShop; coupon redemption in crAPI), API7 SSRF, API8 Security Misconfiguration, API9 Improper Inventory Management. API10 (Unsafe Consumption of APIs) is intentionally not exercised. Each app gets its own attacker class shaped to its vulnerabilities: `CrAPIAttacker` (Kong `/crapi/`), `VAmPIAttacker` (NGINX `/vampi/`), `DVGAAttacker` (NGINX `/dvga/` GraphQL — introspection, nested-resolver DoS, batch login stuffing), `JuiceShopAttacker` (API Gateway `/shop/`), `PixiAttacker` (Kong `/pixi/`).

**Implementation invariants — preserve these or the attack run breaks:**
- All `@task` methods use `catch_response` and accept `200 ≤ status ≤ 503` as success. Attacks deliberately produce 4xx/5xx and we do not want Locust marking those as failures and polluting demo stats.
- Same `--host` gotcha as `locustfile.py`: the Makefile target omits `--host` so each User class's host attribute (Kong / NGINX / API Gateway) is honoured. A CLI `--host` overrides them and routes everything to the wrong gateway.
- `JuiceShopAttacker` is `abstract = True`; a concrete `_JuiceShopAttacker` is registered only when `API_GW_URL` is set. Do not lose this guard or the attack file fails on labs where the API Gateway URL is not configured.
- **BOLA requires authenticated context.** `VAmPIAttacker` and `JuiceShopAttacker` both register a fresh attacker user and log in during `on_start()`, then carry the resulting Bearer token on all API1 BOLA tasks. Without the auth header, Noname sees anonymous enumeration rather than BOLA. `CrAPIAttacker` follows the same pattern. Do not strip auth from BOLA task calls. `VAmPIAttacker` also initialises the VAmPI SQLite DB via `/vampi/createdb` once per process (gated by `_db_initialized`) — same pattern as `VAmPIUser` in `locustfile.py`.

### CI lint
`make lint` (and the `lint.yml` workflow) passes at the ansible-lint **production** profile with zero failures and zero warnings; `terraform fmt -check -recursive`, `terraform validate`, and `tflint --chdir=terraform --recursive` are all clean. A small `.ansible-lint` at the repo root skips two opinionated rules (`var-naming[no-role-prefix]` for `extra-vars` shared across roles, and `yaml[colons]` for vertically aligned `defaults/main.yml`). Each child terraform module has its own `versions.tf` declaring `required_version >= 1.5` and `aws ~> 5.0` — tflint enforces this even though the root already does.

**SSH key validate fallback.** `aws_key_pair.lab.public_key` reads `keys/lab_key.pub` via `file()`. Terraform validate evaluates `file()` at parse time, but the CI runner has no `keys/` directory (gitignored — the keypair is generated locally by `make keys` before `make apply`). The resource therefore wraps the read in `fileexists()`:

```hcl
public_key = fileexists("${path.root}/../keys/lab_key.pub") ? file("${path.root}/../keys/lab_key.pub") : "ssh-ed25519 AAAA…AAAA ci-validate-stub"
```

The stub never reaches AWS in normal use — it only fires when the key is absent, which only happens in CI (where validate runs but apply does not). Apply any new resource that reads a local file the same way: wrap in `fileexists()` so CI doesn't have to materialise the file.

## Known TODOs / Incomplete Areas

- **HTTPS / TLS**: ALB listeners are HTTP only. Add ACM certificate + HTTPS listeners for any scenario requiring TLS-in-transit testing.
- **Cluster headroom**: three `t3.medium` hosts each running a sensor task plus 1–2 gateway/app tasks is reasonably packed. Bumping any task's memory (Kong, NGINX, or vulnerable apps) likely requires a bigger instance type or a placement-strategy change.

## Ansible Implementation Notes — Do Not Regress These

- `ansible.cfg` disables ControlMaster (`ControlMaster=no`) to avoid stale SSH socket errors when going through the bastion. `pipelining = True` keeps performance acceptable.
- The common play uses `serial: 1` to avoid overloading the bastion with parallel ProxyJump connections.
- The ECS AMI ships `curl-minimal` — do not install `curl` via DNF (conflict). Use `uri` module for HTTP tasks instead.
- The `pixi` vulnerable app uses `mccutchen/go-httpbin:latest` (the canonical 42crunch pixi image is not publicly available).
- Noname integration engine ID is fetched dynamically via `GET /api/v3/engines` — no vault variable needed for it.
- The `nginx` role runs on `localhost` and checks the NGINX ALB (not the ECS node directly); `nginx_alb_dns` is passed as an extra-var from Terraform output.
- No `version:` key in any Docker Compose files — it is obsolete in modern Docker and generates warnings.
- The `noname_integration` role does a `GET /api/v3/sources` first and only POSTs to register `lab-kong`, `lab-nginx`, and `lab-api-gateway` if the alias is not already present. Without this guard, every `make provision` run creates a new duplicate (the API does not return 409 on conflict — it just creates another). Connectors appear in the `GET /api/v3/sources` response with `"type": "CONNECTOR"`; `GET /api/v3/connectors` returns an HTML SPA page and cannot be used for idempotency checks.
- After pulling new crAPI images that change env-var shape (TLS/MongoDB/Postgres credential vars), the postgres and mongo volumes must be wiped once with `cd /opt/apps/crapi && sudo docker-compose down -v` on the apps host. The init env vars (`POSTGRES_PASSWORD`, `MONGO_INITDB_ROOT_*`) only apply to a fresh data dir; existing volumes keep the old credentials and break authentication from the application services.
- Existing `t3.small` ECS hosts from earlier deploys do not pick up the `t3.medium` launch template automatically. Trigger an ASG instance refresh (or terminate the old hosts one at a time) so the new launch template takes effect. The sensor's 512 MiB will not schedule on the old t3.small instances alongside a gateway task.
- **NGINX must re-resolve apps_alb at request time, not config load.** `nginx.conf.template` uses a `resolver` directive plus a server-scope `set $apps_alb "${APPS_ALB_DNS}";` and `proxy_pass http://$apps_alb:port` (variable in the URL). NGINX only consults the resolver when the upstream URL contains a variable — the same hostname inside a static `upstream { server hostname; }` block resolves once at config load and caches the IP forever. ALB IPs rotate, so a static upstream silently dies when AWS shuffles nodes (`connect() failed (113: No route to host)`). Pair the variable proxy_pass with an explicit `rewrite ^/<prefix>/(.*)$ /$1 break;` in each location, and drop the trailing slash on `proxy_pass`; variable-based proxy_pass does not auto-strip the location prefix the way a static `upstream` does, and without the rewrite POSTs hit the upstream as `/vampi/users/v1/login` (405) instead of `/users/v1/login`.
- **Identity pool tunables.** `USER_POOL_SIZE=2000` and `IDENTITY_ROTATION_INTERVAL=5` are global. Per-class seed defaults are `USER_POOL_SEED_PER_INSTANCE_VAMPI=200`, `USER_POOL_SEED_PER_INSTANCE_CRAPI=400`, `USER_POOL_SEED_PER_INSTANCE_JUICESHOP=200`. The CRAPI default is highest because it has the fewest spawned instances (weight=1 vs 2 for VAmPI/JuiceShop) and slow signup, so each instance must contribute more. The classic `USER_POOL_SEED_PER_INSTANCE` env var is now the fallback for VAmPI only. With these defaults at TRAFFIC_USERS=50, all three pools fill within ~8 min: VAmPI capped in <1 min, JuiceShop at ~3 min, CrAPI at ~8 min. The seed phase produces a registration burst at startup that briefly loads the apps; expect a 1-2 % failure rate during it (mostly 502s). Apps databases accumulate ~2000 user records per service over a run; only `make destroy` + redeploy resets them.
