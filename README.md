# Akamai API Security Lab

Repeatable AWS lab environment for testing and learning Akamai API Security (formerly Noname Security). Provisions AWS infrastructure via Terraform, configures it via Ansible, and runs five vulnerable API applications behind three API gateways. All three Noname traffic sources — Kong plugin, NGINX plugin, and the AWS ECS host-level Sensor — register with the engine and report end-to-end.

**Region**: us-east-2 (Ohio) | **Terraform state**: local

---

## Architecture

```
Internet → ALB (public subnets)
              ├── Kong OSS ALB              port 8000 (proxy), 8001 (admin)
              ├── NGINX/OpenResty ALB       port 80
              └── Anypoint Flex Gateway ALB port 80

           ECS EC2 cluster (private subnets, t3.medium)
              ├── Kong OSS container              ← nonamesecurity plugin baked in   (lab-kong)
              ├── NGINX/OpenResty container       ← Noname Lua plugin baked in       (lab-nginx)
              ├── Anypoint Flex Gateway container ← registration.yaml from Secrets Manager
              └── Noname Sensor (DaemonSet)       ← one per host, host-network NIC sniff (lab-aws-ecs)

           Apps host EC2 (private subnet)
              ├── crAPI       :8080   OWASP crAPI vulnerable app
              ├── Pixi        :8888   go-httpbin (stateless REST)
              ├── VAmPI       :5000   Flask/SQLite vulnerable REST API
              ├── DVGA        :5013   Flask/Graphene vulnerable GraphQL API
              └── Juice Shop  :3000   OWASP Juice Shop (behind Flex Gateway proxy)
```

**Traffic routing:**

| Gateway | Path | Backend |
|---|---|---|
| Kong | `/crapi/` | apps:8080 |
| Kong | `/pixi/` | apps:8888 |
| Kong | `/sample/` | httpbin.org |
| NGINX | `/vampi/` | apps:5000 |
| NGINX | `/dvga/` | apps:5013 |
| Flex Gateway | `/shop/` | apps:3000 (Juice Shop) |

The Kong Admin API (port 8001) is restricted to `admin_cidr` in the security group. The Flex Gateway proxy API is configured in Anypoint API Manager; the Noname Sensor (DaemonSet) gives the engine visibility into Flex Gateway → Juice Shop traffic since the Mulesoft custom-policy path does not apply to Flex Gateway-served APIs (see "Known limitations").

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

The Noname plugin zip files are not included in this repo. Obtain them from your Akamai/Noname tenant and drop them in `integration-files/` before running `make plugin-images`.

| File | Where to get it |
|---|---|
| `integration-files/noname-security-kong-policy.zip` | Akamai/Noname tenant portal or support |
| `integration-files/noname-security-nginx-policy.zip` | Akamai/Noname tenant portal or support |

You also need the following from your Noname tenant:

- **Tenant URL** — e.g., `https://yourname-lab.nonamesec.com` (used in the Ansible vault)
- **Service account client ID and secret** — create one under **Settings → Service Accounts** (used in the Ansible vault)
- **AWS ECS integration profile** — create one under **Settings → Integrations → Traffic Sources → Add Integration → AWS ECS → Create profile**. The wizard returns a CloudShell deployment script that contains all the values needed by the Sensor: `ENGINE_URL`, `SNIFF_SOURCE_KEY`, `SNIFF_SOURCE_INDEX`, the sensor image URI, and a JSON document with GCP Artifact Registry credentials. Copy these into `terraform/terraform.tfvars` (see Configuration below). The integration profile must exist **before** `terraform apply`, otherwise the Sensor task starts with empty source values and fails.

## Files you need from MuleSoft (Anypoint Flex Gateway)

Flex Gateway runs in **connected mode**, which requires a `registration.yaml` generated from your Anypoint Platform account. This is a one-time step per environment.

```bash
# Generate registration.yaml (run from the repo root)
docker run --entrypoint flexctl -u $UID \
  -v "$(pwd)":/registration \
  mulesoft/flex-gateway \
  registration create \
  --organization=<your-org-id> \
  --token=<your-connected-app-token> \
  --output-directory=/registration \
  --connected=true \
  <gateway-name>
```

The org ID and token come from your Anypoint Platform account. After generating `registration.yaml`, store it in AWS Secrets Manager:

```bash
aws secretsmanager put-secret-value \
  --secret-id "/${project_name}/mulesoft/registration-yaml" \
  --secret-string "$(cat registration.yaml)" \
  --profile SA_Standard_Access-491489166083 \
  --region us-east-2
```

The Secrets Manager secret is created by `make apply` (with a placeholder). The above command updates the placeholder with the real value. The ECS task injects the secret as the `FLEX_REGISTRATION_YAML` environment variable, and `docker/mulesoft/entrypoint.sh` writes it to `/etc/mulesoft/flex-gateway/conf.d/registration.yaml` at container startup — this is the path the gateway agent's directory watcher monitors. The base image's actual runtime is `/init` (which sets `FLEX_CONFIG_DIR` and execs `flex-agent`), so the wrapper entrypoint exec's `/init` after writing the file. Because the image runs as a non-root user (uid 65532), the Dockerfile briefly switches to root to `mkdir -p /etc/mulesoft/flex-gateway/conf.d && chown -R 65532:0` it before switching back.

---

## Anypoint API Manager — Juice Shop proxy API

Once Flex Gateway is registered in connected mode, envoy comes up with **zero listeners** and the gateway returns `502 Bad Gateway` on every request until you deploy a proxy API to it from Anypoint API Manager. Without this step the `/shop/` route does not work, and the `lab-aws-ecs` Sensor source has no Flex Gateway traffic to capture.

This is a one-time, manual step in the Anypoint UI (the lab does not automate it):

1. In Anypoint Platform, switch to the environment where your Flex Gateway is registered.
2. Open **API Manager** → **Add API** → **Add new API** → **Add proxy**.
3. Configure the proxy:
   - **Name**: e.g., `lab-juiceshop-proxy`.
   - **Implementation URI**: the internal apps ALB on Juice Shop's port. Get it from `cd terraform && terraform output apps_alb_dns` and append `:3000`. Example: `http://internal-yourname-akamai-lab-apps-int-alb-…elb.amazonaws.com:3000`.
   - **Downstream Port**: `8081` — **must match** the Flex Gateway container's `containerPort`/`hostPort`. A mismatch produces 502s with no other obvious clue.
   - **Path**: `/shop/`.
4. Save and deploy to your registered Flex Gateway runtime. Anypoint pushes the configuration to the connected gateway within 30 seconds.

Verify:

```bash
MULE_ALB=$(cd terraform && terraform output -raw mulesoft_alb_dns)
curl -s "http://${MULE_ALB}/shop/api/Products" | head -c 120
# → Juice Shop products JSON
```

Until the proxy API deploys, this curl returns `<title>502 Bad Gateway</title>` from envoy.

---

## Configuration

### terraform/terraform.tfvars

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

### ansible/vault.yml

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

All other fields (`vault_anypoint_*`, `vault_kong_admin_token`, etc.) can stay as `REPLACE` placeholders — they are only used for features not yet enabled.

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
# Copy and edit Terraform variables
cp terraform/terraform.tfvars.example terraform/terraform.tfvars
# → Edit: set project_name, aws_profile, admin_cidr

# Create vault password file and encrypt vault.yml from the example template
make vault-create

# Fill in your Noname tenant URL and service account credentials
make vault-edit
```

---

### Phase 3 — Deploy base infrastructure

```bash
make deploy
```

This runs `terraform init → apply → ansible-playbook site.yml` in sequence. Expect 10–15 minutes. It:

- Creates the VPC, subnets, IGW, NAT GW, security groups
- Launches the ECS cluster (3× t3.medium EC2 nodes — t3.small is too small once the Sensor lands on every host) and the apps EC2 host
- Starts Kong, NGINX, and Anypoint Flex Gateway as ECS tasks using public/base images, plus the Noname Sensor as a per-host DaemonSet pulled from the private GCP Artifact Registry
- Installs and starts crAPI, Pixi, VAmPI, DVGA, and Juice Shop on the apps host
- Registers Kong and NGINX as traffic source integrations in your Noname tenant (the AWS ECS source — `lab-aws-ecs` — was created in the Noname UI before `terraform apply` and is already populated)

At this point the gateways are running but using vanilla images (no Noname plugin). The Kong and NGINX integrations will show in the Noname UI but appear offline because no plugin traffic is flowing yet. The Sensor (`lab-aws-ecs`) starts reporting as soon as host traffic crosses any cluster NIC.

---

### Phase 4 — Noname sensor plugins

This phase bakes the Noname Lua plugins into custom Docker images, pushes them to ECR, and wires them into the ECS task definitions. The Kong and NGINX zip files in `integration-files/` must be present (the Mulesoft policy zip is not used — see "Known limitations").

```bash
# Step 1: Build and push plugin images to ECR
make plugin-images
```

This creates ECR repos, builds the Kong, NGINX, and Anypoint Flex Gateway Docker images (Kong and NGINX with Noname plugins installed), pushes all three to ECR, and writes `terraform/plugin.auto.tfvars` with the ECR image URIs and `noname_plugin_enabled = true`. The Kong and NGINX Dockerfiles both patch the Noname plugin's `prevention.lua` with a type guard before the `next()` call — without this fix, a malformed engine response (Lua string instead of rules table) crashes the plugin and returns 500 to the client.

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
# Capture ALB hostnames
KONG_ALB=$(cd terraform && terraform output -raw kong_alb_dns)
NGINX_ALB=$(cd terraform && terraform output -raw nginx_alb_dns)

# Initialize VAmPI's SQLite database (required once per deployment)
curl -s http://${NGINX_ALB}/vampi/createdb

# Smoke test each route
curl -s http://${KONG_ALB}/pixi/uuid                 # → {"uuid": "..."}
curl -s http://${NGINX_ALB}/vampi/users/v1           # → {"users": [...]}
curl -s -o /dev/null -w "%{http_code}" http://${KONG_ALB}/crapi/  # → 200

# Flex Gateway (only if the Anypoint proxy API is deployed — see "Anypoint API Manager" section)
MULE_ALB=$(cd terraform && terraform output -raw mulesoft_alb_dns)
curl -s -o /dev/null -w "%{http_code}" http://${MULE_ALB}/shop/api/Products  # → 200, or 502 if proxy not yet deployed

# Confirm Kong has the plugin and all three routes
curl -s http://${KONG_ALB}:8001/plugins | python3 -c \
  "import sys,json; [print(p['name']) for p in json.load(sys.stdin)['data']]"
# nonamesecurity

curl -s http://${KONG_ALB}:8001/routes | python3 -c \
  "import sys,json; [print(r['name']) for r in json.load(sys.stdin)['data']]"
# crapi-route
# pixi-route
# sample-route
```

In the Noname UI, Kong, NGINX, and the AWS ECS Sensor (`lab-aws-ecs`) should all show as **Online** within 1–2 minutes of traffic hitting the gateways.

---

### Phase 6 — Traffic generation

Two separate Locust files drive traffic at the lab — run them as distinct phases of a demo, not at the same time. Mixing them poisons the behavioural baseline.

**Step 1 — baseline (`make traffic`).** Exercises all five vulnerable apps with realistic happy-path requests so the Noname engine can learn normal patterns per source. Let it run for at least 30 minutes on the first build before moving on.

Noname's behavioural engine learns per-source baselines from the diversity of authenticated identities, not just from raw request volume. Each authenticated User class (`VAmPIUser`, `CrAPIUser`, `JuiceShopUser`) maintains a class-level shared identity pool — instances seed the pool with fresh registrations on `on_start` and rotate through it every few tasks, registering new identities until the pool reaches `USER_POOL_SIZE` and then recycling existing entries. `HttpBinUser` and `DVGAUser` stay stateless (no auth flow to differentiate clients on). Expect a registration burst during the first 5–10 minutes of a run as the pools fill, and ~2000 user records per stateful service accumulating in the apps databases (crAPI Postgres + Mongo, VAmPI SQLite, Juice Shop SQLite) — only `make destroy` + redeploy resets them.

```bash
# Install Locust into .venv (once, after make setup)
make traffic-install

# Run headless baseline traffic — Ctrl+C to stop
make traffic

# Or launch the Locust web UI at http://localhost:8089 for interactive control
make traffic-ui

# Tune volume (defaults are 50 users / 5 spawn-rate)
TRAFFIC_USERS=100 TRAFFIC_RATE=10 make traffic

# Tune identity pooling (defaults shown)
USER_POOL_SIZE=2000 USER_POOL_SEED_PER_INSTANCE=50 IDENTITY_ROTATION_INTERVAL=5 make traffic
```

**Step 2 — OWASP API Top 10 attacks (`make traffic-owasp`).** Once the baseline has trained, fire attacks across the same gateways so Noname's Issues tab populates with detection events. Five attacker classes, one per app:

| Attacker | Gateway | OWASP focus |
|---|---|---|
| `CrAPIAttacker` | Kong `/crapi/` | API1 BOLA on user/profile and orders, API2 credential stuffing, API3 mass-assignment signup, API5 BFLA on `/workshop/api/management/*`, API7 SSRF via `contact_mechanic.mechanic_api`, API9 inventory probing on `/v1/` |
| `VAmPIAttacker` | NGINX `/vampi/` | API2 SQL injection on `/users/v1/login`, API1 BOLA on `/users/v1/{username}`, API5 BFLA on `/_debug`, API3 mass-assignment register |
| `DVGAAttacker` | NGINX `/dvga/` | API8 schema introspection, API4 deeply-nested resolver DoS, API2 batched login mutation stuffing, API3 BOPLA via `createPaste.ownerId`, API1 paste-id walking |
| `JuiceShopAttacker` | Flex Gateway `/shop/` | API2 `' OR 1=1--` login SQLi, API1 BOLA on `Users/{id}` and `basket/{id}`, API3 role=admin mass assignment on register, API5 BFLA on `/authentication-details`, API7 SSRF via `/profile/image/url`, API8 `/api-docs` recon, API9 path traversal on `/shop/ftp/...`, XSS in feedback comments |
| `PixiAttacker` | Kong `/pixi/` | API4 256 KB oversized POST and `/pixi/delay/10` worker tie-up, API8 method bypass (TRACE/OPTIONS/PATCH on `/anything/admin`), header smuggling on `/pixi/headers` |

Coverage spans 9 of the 10 OWASP API Security 2023 categories. **API6** (Unrestricted Access to Sensitive Business Flows) and **API10** (Unsafe Consumption of APIs) are out of scope for this lab.

```bash
# Headless attack run — Ctrl+C to stop
make traffic-owasp

# Web UI variant at http://localhost:8089 — interactive control over which classes fire
make traffic-owasp-ui

# Tune volume (defaults are 10 users / 2 spawn — intentionally lower than baseline)
ATTACK_USERS=20 ATTACK_RATE=4 make traffic-owasp
```

In the Noname UI, watch the **Issues** / **Runtime** tab on `lab-kong`, `lab-nginx`, and `lab-aws-ecs` while the run progresses — BOLA walks, credential stuffing, and SQL injection are typically the first patterns to surface. Every attack task wraps `catch_response` and accepts the full 200–503 range as success, so locust's stats stay focused on network reachability rather than the HTTP errors the gateway/app correctly returns.

---

## Application reference

All traffic should go through the gateway URLs — not directly to the apps — so Noname can observe it.

| App | Gateway | URL path | Notes |
|---|---|---|---|
| crAPI | Kong | `/crapi/` | Full web UI + REST API. Registration requires MailHog for email verification (see below). |
| Pixi (go-httpbin) | Kong | `/pixi/` | Stateless httpbin API. No auth required. Good for basic request/response exploration. |
| VAmPI | NGINX | `/vampi/` | Flask REST API with SQLite. OWASP API Top 10 vulnerabilities. Must run `createdb` first. |
| DVGA | NGINX | `/dvga/` | Flask + Graphene GraphQL API. Endpoint at `/dvga/graphql`. Vulnerable to introspection and injection. |
| Juice Shop | Flex Gateway | `/shop/` | OWASP Juice Shop. Reached via the Anypoint Flex Gateway proxy API; Sensor (DaemonSet) provides the Noname coverage for this path. |

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

---

## Tear-down

```bash
make destroy
```

Destroys all AWS resources (VPC, ECS cluster, EC2 instances, ALBs, ECR repos, SSM parameters, Secrets Manager secrets). Takes 5–10 minutes. Does **not** delete your local files: `keys/`, `.venv/`, `~/.vault_pass`, or the Terraform state file.

After destroy, clean up local Terraform cache if desired:

```bash
make clean                           # removes .venv and terraform/.terraform
rm -f terraform/plugin.auto.tfvars  # remove ECR URIs (gitignored, safe to delete)
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
make plugin-images     # Phase 4, step 1 — rebuilds ECR repos; pushes Kong, NGINX, and Flex Gateway images
make apply             # Phase 4, step 2
make provision-plugins # Phase 4, step 3
make apply             # Phase 4, step 4
# Then Phase 5 verification and Phase 6 traffic
```

After rebuild, also re-store the Flex Gateway `registration.yaml` in Secrets Manager — `make destroy` deletes the secret along with all other resources:

```bash
aws secretsmanager put-secret-value \
  --secret-id "/${project_name}/mulesoft/registration-yaml" \
  --secret-string "$(cat registration.yaml)" \
  --profile SA_Standard_Access-491489166083 \
  --region us-east-2
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
| `/shop/*` returns `502 Bad Gateway` from envoy | Flex Gateway is registered but no proxy API has been deployed to it from Anypoint API Manager | Deploy a proxy API in Anypoint API Manager pointing at the apps ALB on port 3000 with **Downstream Port 8081** — see "Anypoint API Manager — Juice Shop proxy API" |
| `lab-aws-ecs` source stays in `PENDING` with 0 requests | Sensor task can't fit on an EC2 host (insufficient memory) — usually after a config change pushed memory above the per-host headroom | Check `aws ecs describe-services …noname-sensor`. Either trim a gateway task's memory or scale the ASG up; sensors are a `DAEMON` schedule so one needs to fit on every host. |
| `docker: permission denied` | Docker group not active in current shell | Log out and back in, or run `newgrp docker` |
| `make provision-plugins` runs but Kong still has 0 routes | Ran `make provision-plugins` from wrong directory causing bad terraform output | Run directly from the repo root; the Makefile handles the `cd terraform` internally |

---

## Known limitations / not yet implemented

| Feature | Status |
|---|---|
| Mulesoft custom policy on Flex Gateway | Not viable. `noname-security-mulesoft-policy.zip` is packaged as a Mule 4 `mule-policy` and only applies to APIs running on the Mule 4 Runtime. APIs served by Flex Gateway (which is what this lab runs) show "Not covered: there is no policy implementation for the runtime version where this API is running" in API Manager, and `install_mule.pyz` is a dead end against them. Per Noname documentation, Flex Gateway is supported by the **Noname Sensor** instead — that is the path the lab takes, and `lab-aws-ecs` covers Flex Gateway → Juice Shop traffic. |
| HTTPS / TLS | ALB listeners are HTTP only. Add ACM certificates and HTTPS listeners for TLS-in-transit testing scenarios. |
| Remote Terraform state | State is stored locally. For shared team use, configure an S3 + DynamoDB backend in `terraform/main.tf`. |
| Cluster headroom | Three `t3.medium` hosts each running a Sensor task plus 1–2 gateway/app tasks is reasonably packed. Bumping any task's memory (Kong, NGINX, Mulesoft, vulnerable apps) will require either a bigger instance type or a placement-strategy change. |
