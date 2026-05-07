#!/usr/bin/env bash
# Interactive wizard: generates terraform/terraform.tfvars and ansible/vault.yml
set -uo pipefail

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
RESET='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
TFVARS="${REPO_ROOT}/terraform/terraform.tfvars"
VAULT_YML="${REPO_ROOT}/ansible/vault.yml"
VAULT_PASS="${HOME}/.vault_pass"
ANSIBLE_VAULT="${REPO_ROOT}/.venv/bin/ansible-vault"

prompt() {
    local var_name="$1" prompt_text="$2" default_value="${3:-}" secret="${4:-false}"
    if [[ -n "${default_value}" ]]; then
        printf "${BOLD}%s${RESET} [%s]: " "${prompt_text}" "${default_value}"
    else
        printf "${BOLD}%s${RESET}: " "${prompt_text}"
    fi
    local value=""
    if [[ "${secret}" == "true" ]]; then
        read -r -s value; echo ""
    else
        read -r value
    fi
    [[ -z "${value}" && -n "${default_value}" ]] && value="${default_value}"
    printf -v "${var_name}" '%s' "${value}"
}

echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════════════════╗${RESET}"
echo -e "${BOLD}║    Akamai API Security Lab — Configuration Wizard            ║${RESET}"
echo -e "${BOLD}╚══════════════════════════════════════════════════════════════╝${RESET}"
echo ""

# ── Prerequisites check ────────────────────────────────────────────────────────
echo -e "${YELLOW}Checking prerequisites...${RESET}"
MISSING=()
[[ -d "${REPO_ROOT}/.venv" ]] || MISSING+=("make setup  (Python venv missing)")
[[ -f "${REPO_ROOT}/keys/lab_key" ]] || MISSING+=("make keys   (SSH keypair missing)")
if [[ ${#MISSING[@]} -gt 0 ]]; then
    echo -e "${YELLOW}Warning: the following steps have not been run yet:${RESET}"
    for m in "${MISSING[@]}"; do echo "  • ${m}"; done
    echo -e "${YELLOW}You can run them before or after this wizard.${RESET}"
fi

# ── Overwrite guards ───────────────────────────────────────────────────────────
SKIP_TFVARS=false
SKIP_VAULT=false

if [[ -f "${TFVARS}" ]]; then
    printf "\n${YELLOW}terraform/terraform.tfvars already exists. Overwrite? [y/N]: ${RESET}"
    read -r ans
    [[ "${ans,,}" == "y" ]] || { echo "Keeping existing terraform.tfvars."; SKIP_TFVARS=true; }
fi

if [[ -f "${VAULT_YML}" ]]; then
    printf "${YELLOW}ansible/vault.yml already exists. Overwrite? [y/N]: ${RESET}"
    read -r ans
    [[ "${ans,,}" == "y" ]] || { echo "Keeping existing vault.yml."; SKIP_VAULT=true; }
fi

if [[ "${SKIP_TFVARS}" == "true" && "${SKIP_VAULT}" == "true" ]]; then
    echo -e "\n${GREEN}Nothing to do — both files kept as-is.${RESET}"
    exit 0
fi

# ── Detect public IP ───────────────────────────────────────────────────────────
MY_IP=""
if [[ "${SKIP_TFVARS}" != "true" ]]; then
    printf "\nDetecting your public IP... "
    MY_IP=$(curl -sf --max-time 5 https://ifconfig.me \
         || curl -sf --max-time 5 https://api.ipify.org \
         || curl -sf --max-time 5 https://checkip.amazonaws.com | tr -d '[:space:]' \
         || echo "")
    [[ -n "${MY_IP}" ]] && echo "${MY_IP}" || echo "(could not detect)"
fi

# ── Core settings ──────────────────────────────────────────────────────────────
if [[ "${SKIP_TFVARS}" != "true" ]]; then
    echo ""
    echo -e "${BOLD}── Core settings ───────────────────────────────────────────────${RESET}"
    prompt PROJECT_NAME   "Project name (prefix for all AWS resources)" "akamai-lab"
    prompt AWS_REGION     "AWS region" "us-east-2"
    prompt AWS_PROFILE    "AWS CLI profile" "SA_Standard_Access-491489166083"
    prompt INSTANCE_TYPE  "ECS instance type" "t3.medium"
    ADMIN_CIDR_DEFAULT="${MY_IP:+${MY_IP}/32}"
    prompt ADMIN_CIDR     "Your public IP (admin_cidr, e.g. 1.2.3.4/32)" "${ADMIN_CIDR_DEFAULT}"
fi

# ── Noname / Akamai API Security ───────────────────────────────────────────────
if [[ "${SKIP_VAULT}" != "true" ]]; then
    echo ""
    echo -e "${BOLD}── Noname / Akamai API Security ────────────────────────────────${RESET}"
    echo    "  Settings → Integrations → Service Accounts in the Noname UI"
    echo ""
    prompt NONAME_TENANT_URL    "Tenant URL (e.g. https://myorg.nonamesec.com)" ""
    prompt NONAME_CLIENT_ID     "Service account client ID" ""
    prompt NONAME_CLIENT_SECRET "Service account client secret (hidden)" "" "true"

    # ── Anypoint Platform ──────────────────────────────────────────────────────
    echo ""
    echo -e "${BOLD}── Anypoint Platform (MuleSoft Flex Gateway) ───────────────────${RESET}"
    prompt ANYPOINT_CLIENT_ID     "Anypoint client ID" ""
    prompt ANYPOINT_CLIENT_SECRET "Anypoint client secret (hidden)" "" "true"
    prompt MULE_LICENSE_KEY       "Mule license key — leave blank to skip (hidden)" "" "true"
fi

# ── Noname Sensor (optional) ───────────────────────────────────────────────────
NONAME_ENGINE_URL=""
NONAME_SNIFF_SOURCE_KEY=""
NONAME_SNIFF_SOURCE_IDX="1"
NONAME_SENSOR_IMAGE=""
NONAME_JFROG_CREDS=""

if [[ "${SKIP_TFVARS}" != "true" ]]; then
    echo ""
    echo -e "${BOLD}── Noname Sensor / DaemonSet — optional ────────────────────────${RESET}"
    echo    "  In the Noname UI: Settings → Integrations → Traffic Sources"
    echo    "  → Add Integration → AWS ECS → Create profile."
    echo    "  The generated CloudShell script contains all values below."
    echo    "  Leave any field blank to skip — add to terraform.tfvars manually later."
    echo ""
    prompt NONAME_ENGINE_URL       "Engine URL (e.g. https://myorg.nonamesec.com/engine)" ""
    if [[ -n "${NONAME_ENGINE_URL}" ]]; then
        prompt NONAME_SNIFF_SOURCE_KEY "Source key (SNIFF_SOURCE_KEY)" ""
        prompt NONAME_SNIFF_SOURCE_IDX "Source index (SNIFF_SOURCE_INDEX)" "1"
        prompt NONAME_SENSOR_IMAGE     "Sensor image URI (us-central1-docker.pkg.dev/…)" ""
        printf "${BOLD}JFrog credentials JSON (single-line, leave blank to skip)${RESET}: "
        read -r NONAME_JFROG_CREDS
    fi
fi

# ── Write terraform/terraform.tfvars ──────────────────────────────────────────
if [[ "${SKIP_TFVARS}" != "true" ]]; then
    echo ""
    echo -e "Writing ${BOLD}terraform/terraform.tfvars${RESET}..."
    cat > "${TFVARS}" <<EOF
# Generated by make configure — $(date -u +%Y-%m-%dT%H:%M:%SZ)
# terraform.tfvars is gitignored — never commit it.

# ── Core ──────────────────────────────────────────────────────────────────────
project_name       = "${PROJECT_NAME}"
aws_region         = "${AWS_REGION}"
aws_profile        = "${AWS_PROFILE}"
vpc_cidr           = "10.0.0.0/16"
availability_zones = ["${AWS_REGION}a", "${AWS_REGION}b"]
instance_type      = "${INSTANCE_TYPE}"
admin_cidr         = "${ADMIN_CIDR}"
EOF

    if [[ -n "${NONAME_ENGINE_URL}" ]]; then
        cat >> "${TFVARS}" <<EOF

# ── Noname Sensor (DaemonSet) ─────────────────────────────────────────────────
noname_engine_url         = "${NONAME_ENGINE_URL}"
noname_sniff_source_key   = "${NONAME_SNIFF_SOURCE_KEY}"
noname_sniff_source_index = ${NONAME_SNIFF_SOURCE_IDX}
noname_sniff_source_type  = 201
noname_should_use_ebpf    = false
noname_sensor_image       = "${NONAME_SENSOR_IMAGE}"
EOF
        if [[ -n "${NONAME_JFROG_CREDS}" ]]; then
            printf '\nnoname_jfrog_credentials_json = %s\n' "${NONAME_JFROG_CREDS}" >> "${TFVARS}"
        fi
    fi
    echo -e "${GREEN}  ✓ terraform/terraform.tfvars${RESET}"
fi

# ── Write and encrypt ansible/vault.yml ───────────────────────────────────────
if [[ "${SKIP_VAULT}" != "true" ]]; then
    echo -e "Writing ${BOLD}ansible/vault.yml${RESET}..."

    if [[ ! -f "${VAULT_PASS}" ]]; then
        python3 -c "import secrets; print(secrets.token_urlsafe(32))" > "${VAULT_PASS}"
        chmod 600 "${VAULT_PASS}"
        echo -e "${GREEN}  ✓ Created ${VAULT_PASS}${RESET}"
        echo -e "${YELLOW}  ⚠ Back this file up to a password manager — it decrypts your vault!${RESET}"
    fi

    cat > "${VAULT_YML}" <<EOF
---
# Generated by make configure — $(date -u +%Y-%m-%dT%H:%M:%SZ)

# AWS credentials — leave as REPLACE if using AWS SSO profiles (recommended)
vault_aws_access_key: "REPLACE"
vault_aws_secret_key: "REPLACE"

# Kong admin token — leave as REPLACE if Kong auth plugin is not enabled
vault_kong_admin_token: "REPLACE"

# MuleSoft Anypoint Platform
vault_anypoint_client_id:     "${ANYPOINT_CLIENT_ID:-REPLACE}"
vault_anypoint_client_secret: "${ANYPOINT_CLIENT_SECRET:-REPLACE}"
vault_mule_license_key:       "${MULE_LICENSE_KEY:-REPLACE}"

# Noname / Akamai API Security
vault_noname_tenant_url:    "${NONAME_TENANT_URL:-REPLACE}"
vault_noname_client_id:     "${NONAME_CLIENT_ID:-REPLACE}"
vault_noname_client_secret: "${NONAME_CLIENT_SECRET:-REPLACE}"
EOF

    if [[ -x "${ANSIBLE_VAULT}" ]]; then
        "${ANSIBLE_VAULT}" encrypt "${VAULT_YML}" \
            --vault-password-file "${VAULT_PASS}" > /dev/null 2>&1
        echo -e "${GREEN}  ✓ ansible/vault.yml written and encrypted${RESET}"
    else
        echo -e "${YELLOW}  ansible/vault.yml written (plaintext).${RESET}"
        echo -e "${YELLOW}  Run 'make setup' then 'make vault-create' to encrypt it.${RESET}"
    fi
fi

# ── Summary ────────────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}${BOLD}Configuration complete!${RESET}"
echo ""
echo "Next steps:"
[[ -d "${REPO_ROOT}/.venv" ]]      || echo "  make setup"
[[ -f "${REPO_ROOT}/keys/lab_key" ]] || echo "  make keys"
echo "  make deploy"
echo ""
