# Akamai API Security Lab

Repeatable AWS lab environment for testing and learning Akamai API Security (formerly Noname Security). Provisions AWS infrastructure via Terraform, configures it via Ansible, and runs five vulnerable API applications behind three API gateways. All three Noname traffic sources — Kong plugin, NGINX plugin, and the AWS API Gateway connector — register with the engine and report end-to-end.

**Region**: us-east-2 (Ohio) | **Terraform state**: local

---

## Architecture

```
Internet → ALB (public subnets)
              ├── Kong OSS ALB        port 8000 (proxy), 8001 (admin)
              └── NGINX/OpenResty ALB port 80

Internet → AWS API Gateway (REST API V1, `lab` stage)
              └── VPC Link → internal NLB → apps EC2 :3000 (Juice Shop)

           ECS EC2 cluster (private subnets, t3.medium)
              ├── Kong OSS container        ← nonamesecurity plugin baked in  (lab-kong)
              ├── NGINX/OpenResty container ← Noname Lua plugin baked in      (lab-nginx)
              └── Noname Sensor (DaemonSet) ← one per host, host-network NIC sniff

           ECS Fargate (private subnets, ephemeral)
              └── Locust traffic tasks      ← launched ad-hoc via 'make traffic-aws'

           Apps host EC2 (private subnet)
              ├── crAPI       :8080   OWASP crAPI vulnerable app
              ├── Pixi        :8888   go-httpbin (stateless REST)
              ├── VAmPI       :5000   Flask/SQLite vulnerable REST API
              ├── DVGA        :5013   Flask/Graphene vulnerable GraphQL API
              └── Juice Shop  :3000   OWASP Juice Shop (behind API Gateway proxy)

           Noname Forwarder stack (CloudFormation)
              └── Kinesis stream ← CloudWatch subscription filter ← API GW access + execution logs
                      └── Sender Lambda → Noname engine            (lab-api-gateway)
```

**Traffic routing:**

| Gateway | Path | Backend |
|---|---|---|
| Kong | `/crapi/` | apps:8080 |
| Kong | `/pixi/` | apps:8888 |
| Kong | `/sample/` | httpbin.org |
| NGINX | `/vampi/` | apps:5000 |
| NGINX | `/dvga/` | apps:5013 |
| API Gateway | `/shop/{proxy+}` | apps:3000 (Juice Shop) |

The Kong Admin API (port 8001) is restricted to `admin_cidr` in the security group. API Gateway **access logs** and **execution logs** (data tracing enabled) both flow to CloudWatch, then through Kinesis subscription filters to the Noname Forwarder Lambda — the Forwarder pairs them by `requestId` via DynamoDB to form complete API transactions for the `lab-api-gateway` connector. Only REST API V1 produces execution logs; HTTP API V2 is not supported by the Forwarder.

NGINX resolves the apps-ALB hostname at request time (10-second answer cache via the in-config `resolver` directive plus a variable-based `proxy_pass`), so AWS rotating ALB node IPs does not cause sticky 502s.

---

## Prerequisites

Install these on your workstation before starting. Terraform is handled by the Makefile — do not install it manually.

| Tool | Notes |
|---|---|
| AWS CLI v2 | Configured with an SSO profile |
| Python 3.10+ | For Ansible venv |
| Docker | For building plugin images |
| GNU Make | Standard on Linux/macOS |
| git | For cloning the repo |

### AWS SSO authentication

This lab uses the `SA_Standard_Access-491489166083` AWS SSO profile. Authenticate before running any `make` targets. Tokens typically expire every 8 hours.

```bash
aws sso login --profile SA_Standard_Access-491489166083
```

Run this again any time you see `Token has expired` or `SSO` errors in command output.

---

## Files you need from Noname/Akamai

The following files are not included in this repo and must be obtained separately.

| File | Where to get it |
|---|---|
| `integration-files/noname-security-kong-policy.zip` | Akamai/Noname tenant portal or support |
| `integration-files/noname-security-nginx-policy.zip` | Akamai/Noname tenant portal or support |
| `integration-files/noname-aws-connector-forwarder.yaml` | Noname UI: Settings → Integrations → Traffic Sources → Add Integration → AWS Connector → Manual → download ZIP, extract YAML |

The `noname-aws-connector-forwarder.yaml` CloudFormation template must be present **before** `make apply` — the `noname_connector` Terraform module is a no-op until the file exists. After extracting the YAML, append an `Outputs` section if the downloaded template lacks one:

```yaml
Outputs:
  KinesisStreamArn:
    Description: ARN of the Noname Kinesis data stream used for CloudWatch log forwarding
    Value: !GetAtt NonameDataStream.Arn
```

You also need the following from your Noname tenant:

- **Tenant URL** — e.g., `https://yourname-lab.nonamesec.com` (used in the Ansible vault)
- **Service account client ID and secret** — create one under **Settings → Service Accounts** (used in the Ansible vault)
- **AWS ECS integration profile** — create one under **Settings → Integrations → Traffic Sources → Add Integration → AWS ECS → Create profile**. The wizard returns a CloudShell deployment script that contains all the values needed by the Sensor: `ENGINE_URL`, `SNIFF_SOURCE_KEY`, `SNIFF_SOURCE_INDEX`, the sensor image URI, and a JSON document with GCP Artifact Registry credentials. Copy these into `terraform/terraform.tfvars` (see Configuration below). The integration profile must exist **before** `terraform apply`, otherwise the Sensor task starts with empty source values and fails.

---

---

## Configuration

The fastest path is the interactive wizard:

```bash
make configure
```

It prompts for every required value, auto-detects your public IP, writes `terraform/terraform.tfvars`, and creates and encrypts `ansible/vault.yml` in one step. The sections below describe the manual equivalent if you need to edit individual values after the fact.

**Before running `make configure`**, ensure `integration-files/noname-aws-connector-forwarder.yaml` is present (see "Files you need from Noname/Akamai" above).

### terraform/terraform.tfvars (manual)

```bash
cp terraform/terraform.tfvars.example terraform/terraform.tfvars
```

Edit the file. Minimum required changes:

```hcl
project_name = "yourname-akamai-lab"            # prefix for all AWS resource names
aws_profile  = "SA_Standard_Access-491489166083" # your AWS SSO profile
admin_cidr   = "YOUR_IP/32"                      # your public IP — restricts SSH + Kong Admin API
```

Get your public IP:
```bash
curl -s https://ifconfig.me
```

The `admin_cidr` is also auto-detected from your current IP when running `make plan`, `make apply`, or `make destroy` — so you don't need to keep it updated in the file.

### ansible/vault.yml (manual)

The vault is an AES256-encrypted YAML file that holds all secrets. The vault password is stored at `~/.vault_pass`.

```bash
make vault-create   # creates ~/.vault_pass (random password) and encrypts vault.yml from the example
make vault-edit     # open the vault in your editor to fill in values
```

Required vault fields for this lab:

```yaml
vault_noname_tenant_url:    "https://yourname-lab.nonamesec.com"
vault_noname_client_id:     "<service account client ID>"
vault_noname_client_secret: "<service account client secret>"
```

All other fields (`vault_kong_admin_token`, etc.) can stay as `REPLACE` placeholders — they are only used for features not yet enabled.

### terraform/terraform.tfvars — Sensor variables

Copy these out of the Noname AWS ECS deployment script. `noname_jfrog_credentials_json` is a JSON document `{"username":"_json_key_base64","password":"<base64 GCP SA key>"}` — pass it via a sensitive heredoc, do not commit it.

```hcl
noname_engine_url             = "https://<tenant>.nonamesec.com/engine"
noname_sniff_source_key       = "<from AWS ECS integration profile>"
noname_sniff_source_index     = 1
noname_sniff_source_type      = 201   # AWS ECS — leave at default
noname_should_use_ebpf        = false # eBPF capture is opt-in
noname_sensor_image           = "us-central1-docker.pkg.dev/noname-artifacts/nns-docker/noname-sensor:<version>"
noname_jfrog_credentials_json = <<EOT
{"username":"...","password":"..."}
EOT
```

---

## Full build-up (first time)

Work through these phases in order. Phases 1 and 2 are one-time setup on your machine. You only repeat Phases 3–6 when redeploying after a destroy.

---

### Phase 1 — Machine setup (one time)

```bash
# Authenticate to AWS
aws sso login --profile SA_Standard_Access-491489166083

# Install Terraform to /usr/local/bin
make install-terraform

# Create Python venv and install Ansible + Galaxy collections
make setup

# Generate ED25519 SSH keypair used to reach ECS nodes via bastion
make keys
```

---

### Phase 2 — Configuration (one time)

```bash
make configure
```

The interactive wizard prompts for every required value (project name, AWS profile, Noname service account credentials, and optionally the Sensor config from the Noname UI deployment script), auto-detects your public IP for `admin_cidr`, writes `terraform/terraform.tfvars`, and creates and encrypts `ansible/vault.yml` in one step.

If you prefer to configure manually, see the [Configuration](#configuration) section below.

---

### Phase 3 — Deploy base infrastructure

```bash
make deploy
```

This runs `terraform init → apply → ansible-playbook site.yml` in sequence. Expect 10–15 minutes. It:

- Creates the VPC, subnets, IGW, NAT GW, security groups
- Launches the ECS cluster (3× t3.medium EC2 nodes — t3.small is too small once the Sensor lands on every host) and the apps EC2 host
- Starts Kong and NGINX as ECS tasks using public/base images, plus the Noname Sensor as a per-host DaemonSet pulled from the private GCP Artifact Registry
- Deploys the Noname Forwarder CloudFormation stack (Kinesis + Lambda) and the AWS API Gateway HTTP API with VPC Link to the apps ALB
- Installs and starts crAPI, Pixi, VAmPI, DVGA, and Juice Shop on the apps host
- Registers Kong, NGINX, and the AWS API Gateway connector (`lab-api-gateway`) as Noname traffic source integrations in your Noname tenant

At this point Kong and NGINX are running but using vanilla images (no Noname plugin). Kong and NGINX integrations appear offline in the Noname UI until the plugin images are deployed. The `lab-api-gateway` connector starts receiving traffic as soon as requests hit the API Gateway `/shop/` route.

---

### Phase 4 — Noname sensor plugins

This phase bakes the Noname Lua plugins into custom Docker images, pushes them to ECR, and wires them into the ECS task definitions. The Kong and NGINX zip files in `integration-files/` must be present.

```bash
# Step 1: Build and push plugin images to ECR
make plugin-images
```

This creates ECR repos, builds the Kong and NGINX Docker images with Noname plugins installed, pushes them to ECR, and writes `terraform/plugin.auto.tfvars` with the ECR image URIs and `noname_plugin_enabled = true`. Both Dockerfiles patch the Noname plugin's `prevention.lua` with a type guard before the `next()` call — without this fix, a malformed engine response (Lua string instead of rules table) crashes the plugin and returns 500 to the client.

```bash
# Step 2: Update ECS task definitions to use the new plugin images
make apply
```

ECS will pull the new images and restart the Kong and NGINX containers (2–3 minutes). Kong starts with zero config at this point.

```bash
# Step 3: Push Kong declarative config and capture NGINX source key
make provision-plugins
```

This playbook:
- Authenticates to the Noname API and fetches the registered source configs
- Pushes Kong's declarative config: three services (crapi, pixi, sample), their routes, and the `nonamesecurity` global plugin with the correct `sourceKey` and `sourceIndex`
- Writes the NGINX `sourceKey` and `sourceIndex` to `terraform/plugin.auto.tfvars`

```bash
# Step 4: Apply the NGINX source key into the ECS task environment
make apply
```

ECS restarts the NGINX container with the correct Noname source credentials as environment variables.

---

### Phase 5 — Verification

```bash
make verify
```

Runs seven smoke-tests with color-coded `[PASS]` / `[FAIL]` output:

1. VAmPI database initialization (`/vampi/createdb` — idempotent)
2. Kong → Pixi route (`/pixi/uuid`)
3. NGINX → VAmPI users route (`/vampi/users/v1`)
4. Kong → crAPI route (`/crapi/`)
5. API Gateway → Juice Shop (`/shop/api/Products`)
6. Kong `nonamesecurity` plugin active
7. Kong routes present: `crapi-route`, `pixi-route`, `sample-route`

Exits 0 when all checks pass, 1 on any failure.

In the Noname UI, Kong, NGINX, and `lab-api-gateway` should all show as **Online** within 1–2 minutes of traffic hitting the gateways.

---

### Phase 6 — Traffic generation

Two separate Locust files drive traffic at the lab — run them as distinct phases of a demo, not at the same time. Mixing them poisons the behavioural baseline.

Traffic can run **locally** (requires Python/venv — Linux/macOS) or **on AWS Fargate** (platform-independent, works on Windows without WSL, runs unattended). The AWS mode is recommended for demos and for Windows users.

#### Option A — Local (Linux/macOS)

```bash
# Install Locust into .venv (once, after make setup)
make traffic-install

# Headless baseline traffic — Ctrl+C to stop
make traffic

# Web UI at http://localhost:8089
make traffic-ui

# Tune volume (defaults: 50 users / 5 spawn-rate)
TRAFFIC_USERS=100 TRAFFIC_RATE=10 make traffic
```

#### Option B — AWS Fargate (platform-independent)

Each `make traffic-aws` launch creates N independent Fargate tasks (default 10), each with its own ENI and private IP. This provides genuine network-level IP diversity in addition to the `X-Forwarded-For` consumer IP injection described below.

```bash
# Build and push the Locust image to ECR (once per lab, requires Docker)
# Prerequisite: make apply-ecr (already done if you ran make deploy)
make traffic-aws-build

# Launch 10 Fargate tasks (5 users each = 50 total) — runs unattended
make traffic-aws

# Tail CloudWatch logs from running tasks
make traffic-aws-logs

# Stop all running tasks
make traffic-aws-stop

# Tune task count and users per task
TRAFFIC_AWS_TASKS=20 TRAFFIC_AWS_USERS=10 make traffic-aws
```

#### Consumer IP diversity

Both local and Fargate modes inject a rotating `X-Forwarded-For` header on every request. Each Locust user instance picks one fake source IP from a pool of 10 RFC 1918 addresses (`10.20.x.y`) and sends it as XFF. The Kong and NGINX ALBs append the real sender IP after the injected value; Noname reads the **first** (leftmost) XFF entry as the original consumer IP — so the engine records 10+ distinct source IPs across all workers, not just the runner's IP. API Gateway traffic is unaffected (`$context.identity.sourceIp` is the actual socket IP; JuiceShop IP diversity relies on user-identity tokens only).

Configure the pool size with `N_CONSUMER_IPS=<n>` (default 10).

#### Identity pooling (baseline only)

Noname's behavioural engine learns per-source baselines from the diversity of authenticated identities, not just from raw request volume. Each authenticated User class (`VAmPIUser`, `CrAPIUser`, `JuiceShopUser`) maintains a class-level shared identity pool — instances seed the pool with fresh registrations on `on_start` and rotate through it every few tasks, registering new identities until the pool reaches `USER_POOL_SIZE` and then recycling existing entries. `HttpBinUser` and `DVGAUser` stay stateless. Expect a registration burst during the first 5–10 minutes of a run as the pools fill, and ~2000 user records per stateful service accumulating in the apps databases (crAPI Postgres + Mongo, VAmPI SQLite, Juice Shop SQLite) — only `make destroy` + redeploy resets them.

At default settings (`USER_POOL_SIZE=2000`, `IDENTITY_ROTATION_INTERVAL=5`, per-class seeds `VAMPI=200`/`CRAPI=400`/`JUICESHOP=200`) all three authenticated pools cap within ~8 min at `TRAFFIC_USERS=50`. Override any tunable as an env-var prefix:

```bash
USER_POOL_SIZE=2000 USER_POOL_SEED_PER_INSTANCE_VAMPI=200 \
USER_POOL_SEED_PER_INSTANCE_CRAPI=400 \
USER_POOL_SEED_PER_INSTANCE_JUICESHOP=200 \
IDENTITY_ROTATION_INTERVAL=5 make traffic
```

**Step 2 — OWASP API Top 10 attacks.** Once the baseline has trained (~30 min), fire attacks across the same gateways so Noname's Issues tab populates with detection events. Five attacker classes, one per app:

```bash
# Local
make traffic-owasp
make traffic-owasp-ui          # web UI variant at http://localhost:8089
ATTACK_USERS=20 ATTACK_RATE=4 make traffic-owasp

# AWS Fargate (uses same task definition as baseline — override via container command)
make traffic-owasp-aws
ATTACK_AWS_TASKS=10 ATTACK_AWS_USERS=5 make traffic-owasp-aws
make traffic-aws-stop          # stops baseline and attack tasks (same family)
```

**Attack coverage** — five attacker classes, one per app:

| Attacker | Gateway | OWASP focus |
|---|---|---|
| `CrAPIAttacker` | Kong `/crapi/` | API1 BOLA on user/profile and orders, API2 credential stuffing, API3 mass-assignment signup, API5 BFLA on `/workshop/api/management/*`, API7 SSRF via `contact_mechanic.mechanic_api`, API9 inventory probing on `/v1/` |
| `VAmPIAttacker` | NGINX `/vampi/` | API2 SQL injection on `/users/v1/login`, API1 BOLA on `/users/v1/{username}`, API5 BFLA on `/_debug`, API3 mass-assignment register |
| `DVGAAttacker` | NGINX `/dvga/` | API8 schema introspection, API4 deeply-nested resolver DoS, API2 batched login mutation stuffing, API3 BOPLA via `createPaste.ownerId`, API1 paste-id walking |
| `JuiceShopAttacker` | API Gateway `/shop/` | API2 `' OR 1=1--` login SQLi, API1 BOLA on `Users/{id}` and `basket/{id}`, API3 role=admin mass assignment on register, API5 BFLA on `/authentication-details`, API7 SSRF via `/profile/image/url`, API8 `/api-docs` recon, API9 path traversal on `/shop/ftp/...`, XSS in feedback comments |
| `PixiAttacker` | Kong `/pixi/` | API4 256 KB oversized POST and `/pixi/delay/10` worker tie-up, API8 method bypass (TRACE/OPTIONS/PATCH on `/anything/admin`), header smuggling on `/pixi/headers` |

Coverage spans 9 of the 10 OWASP API Security 2023 categories. **API6** (Unrestricted Access to Sensitive Business Flows) and **API10** (Unsafe Consumption of APIs) are out of scope for this lab.

In the Noname UI, watch the **Issues** / **Runtime** tab on `lab-kong`, `lab-nginx`, and `lab-api-gateway` while the attack run progresses — BOLA walks, credential stuffing, and SQL injection are typically the first patterns to surface. Every attack task wraps `catch_response` and accepts the full 200–503 range as success, so Locust's stats stay focused on network reachability rather than the HTTP errors the gateway/app correctly returns.

---

## Application reference

All traffic should go through the gateway URLs — not directly to the apps — so Noname can observe it.

| App | Gateway | URL path | Notes |
|---|---|---|---|
| crAPI | Kong | `/crapi/` | Full web UI + REST API. Registration requires MailHog for email verification (see below). |
| Pixi (go-httpbin) | Kong | `/pixi/` | Stateless httpbin API. No auth required. Good for basic request/response exploration. |
| VAmPI | NGINX | `/vampi/` | Flask REST API with SQLite. OWASP API Top 10 vulnerabilities. Must run `createdb` first. |
| DVGA | NGINX | `/dvga/` | Flask + Graphene GraphQL API. Endpoint at `/dvga/graphql`. Vulnerable to introspection and injection. |
| Juice Shop | API Gateway | `/shop/` | OWASP Juice Shop. Reached via AWS API Gateway REST API V1 → VPC Link → internal NLB → apps EC2. Coverage via CloudWatch → Kinesis → Noname Forwarder Lambda (`lab-api-gateway`). |

### VAmPI — initialize database

VAmPI ships with an empty SQLite database. The first call to any `/users/v1/*` endpoint returns `500 Internal Server Error` with `no such table: users` until you hit `/createdb` once.

`make traffic` handles this automatically — `VAmPIUser.on_start()` calls `/vampi/createdb` once per Locust process before any other VAmPI tasks run, gated by a class-level `_db_initialized` flag. Only run the curl manually if you are smoke-testing VAmPI directly:

```bash
curl -s http://${NGINX_ALB}/vampi/createdb
```

### crAPI — email verification via MailHog

crAPI sends registration and order confirmation emails to MailHog, which runs on the apps host with no public endpoint. Access it through an SSH tunnel:

```bash
BASTION=$(cd terraform && terraform output -raw bastion_public_ip)
APPS_IP=$(aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=*apps*" "Name=instance-state-name,Values=running" \
  --profile SA_Standard_Access-491489166083 --region us-east-2 \
  --query 'Reservations[0].Instances[0].PrivateIpAddress' --output text)

ssh -i keys/lab_key \
  -o StrictHostKeyChecking=no \
  -o ProxyJump=ec2-user@${BASTION} \
  -L 8025:localhost:8025 \
  ec2-user@${APPS_IP} -N &

# Open http://localhost:8025 in your browser
```

---

## Day-to-day operations

### Kong config lost after ECS restart

Kong runs in dbless (in-memory) mode. Its routes, services, and plugin config are wiped whenever the ECS task restarts (image update, node replacement, ECS draining). If Kong shows 0 routes or appears offline in Noname:

```bash
make provision-plugins
```

This re-fetches the correct source keys from the Noname API and re-pushes the full declarative config.

### Get current ALB URLs

```bash
cd terraform
terraform output kong_alb_dns
terraform output nginx_alb_dns
terraform output bastion_public_ip
```

### SSH access

```bash
# Bastion (direct)
ssh -i keys/lab_key ec2-user@$(cd terraform && terraform output -raw bastion_public_ip)

# ECS node (through bastion) — get the private IP from the EC2 console or aws ec2 describe-instances
ssh -i keys/lab_key \
  -o StrictHostKeyChecking=no \
  -o ProxyJump=ec2-user@$(cd terraform && terraform output -raw bastion_public_ip) \
  ec2-user@<private-ip>
```

### Kong Admin API tunnel

Use this when you want to point a local tool (Insomnia, Postman, curl) at the Kong Admin API without opening port 8001 to your IP:

```bash
./scripts/kong-tunnel.sh
# Kong Admin API is then available at http://localhost:18001
```

### CI lint and the SSH key fallback

The GitHub Actions Lint workflow runs `terraform fmt -check`, `terraform validate`, and `tflint` on every push. `make lint` runs the same checks locally.

`terraform validate` evaluates `file()` calls at parse time — including the one in `aws_key_pair.lab.public_key` that loads `keys/lab_key.pub`. The CI runner has no such file (the `keys/` directory is gitignored, intentionally), so a bare `file(...)` call would fail validate. The resource is wrapped in `fileexists()` with a stub fallback:

```hcl
resource "aws_key_pair" "lab" {
  key_name   = "${var.project_name}-key"
  public_key = fileexists("${path.root}/../keys/lab_key.pub") \
               ? file("${path.root}/../keys/lab_key.pub") \
               : "ssh-ed25519 AAAA…AAAA ci-validate-stub"
  …
}
```

The stub only ever reaches AWS if you somehow `make apply` without first running `make keys` — don't do that. Locally, after `make keys`, the real public key is read; in CI the stub keeps validate happy and tflint can run. Same pattern applies if you contribute a new resource that reads a local file: wrap it in `fileexists()` so CI doesn't have to materialise the file.

---

## Tear-down

```bash
make destroy
```

Destroys all AWS resources (VPC, ECS cluster, EC2 instances, ALBs, ECR repos, SSM parameters, Secrets Manager secrets). Takes 5–10 minutes. Does **not** delete your local files: `keys/`, `.venv/`, `~/.vault_pass`, or the Terraform state file.

After destroy, clean up local Terraform cache if desired:

```bash
make clean                            # removes .venv and terraform/.terraform
rm -f terraform/plugin.auto.tfvars   # remove plugin ECR URIs (gitignored, safe to delete)
rm -f terraform/traffic.auto.tfvars  # remove traffic ECR URI (gitignored, safe to delete)
```

Keep `keys/lab_key` and `~/.vault_pass` — you will need them if you redeploy.

---

## Rebuilding after destroy

You do **not** need to redo Phase 1 (machine setup) or Phase 2 (configuration). Keys and vault credentials are reused.

Start from Phase 3 and run through Phase 6 in order. One important difference from the first deploy: after `make deploy` you must redo `make plugin-images` even if you already built images before, because:

- `make destroy` deletes the ECR repos
- The ECR image URIs in `plugin.auto.tfvars` become invalid
- `plugin.auto.tfvars` is gitignored and must be regenerated

```bash
make deploy            # Phase 3
make plugin-images     # Phase 4, step 1 — rebuilds ECR repos; pushes Kong and NGINX images
make apply             # Phase 4, step 2
make provision-plugins # Phase 4, step 3
make apply             # Phase 4, step 4
make verify            # Phase 5 — smoke-test all routes
make traffic-aws-build # Phase 6 (Fargate) — rebuilds traffic ECR repo and image
# Then Phase 6 traffic (local or Fargate)
```

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| Any AWS CLI / Terraform / Ansible AWS call fails with "Token has expired" or "SSO" error | AWS SSO session expired | `aws sso login --profile SA_Standard_Access-491489166083` |
| Kong shows 0 routes, or appears offline in Noname | ECS task restarted and lost in-memory config | `make provision-plugins` |
| `/vampi/users/v1` returns an HTML page with `no such table: users` | VAmPI SQLite DB not initialized | `curl -s http://${NGINX_ALB}/vampi/createdb` (or run `make traffic` — locust does it on first start) |
| `make provision-plugins` fails immediately with "Connection refused" to Noname tenant | Transient network error to Noname SaaS | Re-run the command — almost always a one-off |
| NGINX returns 500 for `/vampi/` or `/dvga/`, or Kong returns 500 for `/crapi/*` | Unpatched gateway image deployed (Noname plugin `prevention.lua` bug — `bad argument #1 to 'next' (table expected, got string)` in Kong/NGINX logs) | Rebuild and push the patched images: `make plugin-images && make apply` |
| NGINX returns 502 for `/vampi/*` or `/dvga/*` with `connect() failed (113: No route to host)` in the NGINX logs | Stale apps-ALB IP cached by NGINX after AWS rotated an ALB node | Self-heals within ~10 s thanks to the runtime resolver in `docker/nginx/nginx.conf.template` (variable-based `proxy_pass` + `resolver … valid=10s`). If it persists, the resolver directive or the `set $apps_alb` line was removed — restore them and rebuild the NGINX image. |
| `/shop/*` returns `403 Forbidden` or `503` from API Gateway | VPC Link not yet healthy or security group rule missing between VPC Link SG and apps ALB SG | Check `aws apigatewayv2 get-vpc-links` for `AVAILABLE` status; verify the `aws_security_group_rule.apps_alb_from_api_gw` rule was applied (`make apply`) |
| `lab-api-gateway` stays `PENDING` in Noname UI | CloudWatch subscription filter not yet delivering to Kinesis, or KMS permissions missing on the CW→Kinesis IAM role | Verify `aws cloudwatch describe-subscription-filters` for the API GW log group; check IAM role has `kms:GenerateDataKey` on the Kinesis stream's KMS key |
| `lab-api-gateway` goes offline after previously working; `NonameSender` Lambda logs show `not authorized to perform: dynamodb:GetItem on resource: .../table/NonamePacketPairByRequestId` | `NonameCodeDeployer` auto-updated `NonameSender` to a new code version that expects an unsuffixed DynamoDB table name (`NonamePacketPairByRequestId`) instead of the suffixed name the CFN stack created (`NonamePacketPairByRequestId-{suffix}`). The IAM inline policy only covers the suffixed ARN. | Get the current inline policy from the `NonameSenderFunctionExecu-*` role (`SenderManagement-*` policy name), add `arn:aws:dynamodb:{region}:{account}:table/NonamePacketPairByRequestId` and its `/*` items ARN to the `dynamodb:*` statement's Resource list, then `put-role-policy` it back. The unsuffixed table already exists — do not create a new one. Takes effect within seconds. Note: `terraform apply` targeting the `noname_connector` module will revert this fix (CloudFormation rewrites the inline policy). |
| `make traffic-aws` fails with "task definition not found" | `traffic-aws-build` hasn't been run yet, or ECR URI in `traffic.auto.tfvars` is stale after a `make destroy` | Run `make traffic-aws-build` (requires `make apply-ecr` first if ECR repo was destroyed) |
| `make traffic-aws-logs` returns "log group does not exist" | CloudWatch log group created on first task launch; group exists but no tasks have run yet, or `_tf_outputs` read stale state | Run `make traffic-aws` first; if group still missing run `make apply` |
| Fargate tasks launch but show no traffic in Noname | Tasks use NAT gateway → all tasks share the same egress IP; XFF injection is working but Kong/NGINX SG is blocking the NAT GW IP | ECS SG egress is `0.0.0.0/0`; ALB SG ingress allows all HTTP — traffic should flow. Check `make traffic-aws-logs` for Locust errors |
| `docker: permission denied` | Docker group not active in current shell | Log out and back in, or run `newgrp docker` |
| `make provision-plugins` runs but Kong still has 0 routes | Ran `make provision-plugins` from wrong directory causing bad terraform output | Run directly from the repo root; the Makefile handles the `cd terraform` internally |

---

## Known limitations / not yet implemented

| Feature | Status |
|---|---|
| HTTPS / TLS | ALB listeners are HTTP only. Add ACM certificates and HTTPS listeners for TLS-in-transit testing scenarios. API Gateway already serves HTTPS. |
| Remote Terraform state | State is stored locally. For shared team use, configure an S3 + DynamoDB backend in `terraform/main.tf`. |
| Cluster headroom | Three `t3.medium` hosts each running a Sensor task plus 1–2 gateway/app tasks is reasonably packed. Bumping any task's memory (Kong, NGINX, or vulnerable apps) will require either a bigger instance type or a placement-strategy change. |
