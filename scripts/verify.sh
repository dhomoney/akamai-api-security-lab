#!/usr/bin/env bash
# Smoke-tests all gateway routes and Kong plugin/route config.
# Called by 'make verify' with KONG_ALB_DNS, NGINX_ALB_DNS,
# API_GW_URL, and KONG_ADMIN_URL exported from Makefile _tf_outputs.
set -uo pipefail

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
RESET='\033[0m'

PASS=0
FAIL=0

pass() { echo -e "${GREEN}[PASS]${RESET} $1"; PASS=$((PASS+1)); }
fail() { echo -e "${RED}[FAIL]${RESET} $1"; FAIL=$((FAIL+1)); }
warn() { echo -e "${YELLOW}[WARN]${RESET} $1"; }
info() { echo -e "       $1"; }

: "${KONG_ALB_DNS:?KONG_ALB_DNS not set — is terraform apply done?}"
: "${NGINX_ALB_DNS:?NGINX_ALB_DNS not set — is terraform apply done?}"
: "${KONG_ADMIN_URL:?KONG_ADMIN_URL not set — is terraform apply done?}"

echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════════════════╗${RESET}"
echo -e "${BOLD}║    Akamai API Security Lab — Verification                    ║${RESET}"
echo -e "${BOLD}╚══════════════════════════════════════════════════════════════╝${RESET}"
echo ""

# 1. VAmPI createdb (idempotent — initializes SQLite on a fresh deploy)
echo -e "${BOLD}1. VAmPI — initialize database${RESET}"
STATUS=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 \
    "http://${NGINX_ALB_DNS}/vampi/createdb" 2>/dev/null || echo "000")
if [[ "${STATUS}" == "200" ]]; then
    pass "VAmPI database initialized (HTTP ${STATUS})"
else
    fail "VAmPI createdb returned HTTP ${STATUS} — is the NGINX service up?"
fi

# 2. Pixi route via Kong
echo ""
echo -e "${BOLD}2. Kong → Pixi route${RESET}"
BODY=$(curl -sf --max-time 10 "http://${KONG_ALB_DNS}/pixi/uuid" 2>/dev/null || echo "")
if echo "${BODY}" | grep -q '"uuid"'; then
    pass "Pixi route OK — uuid present in response"
else
    fail "Pixi route — expected '\"uuid\"' in response, got: ${BODY:0:120}"
fi

# 3. VAmPI users route via NGINX
echo ""
echo -e "${BOLD}3. NGINX → VAmPI users route${RESET}"
BODY=$(curl -sf --max-time 10 "http://${NGINX_ALB_DNS}/vampi/users/v1" 2>/dev/null || echo "")
if echo "${BODY}" | grep -q '"users"'; then
    pass "VAmPI users route OK — users list returned"
else
    fail "VAmPI users route — expected '\"users\"' in response, got: ${BODY:0:120}"
fi

# 4. crAPI route via Kong
echo ""
echo -e "${BOLD}4. Kong → crAPI route${RESET}"
STATUS=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 \
    "http://${KONG_ALB_DNS}/crapi/" 2>/dev/null || echo "000")
if [[ "${STATUS}" == "200" ]]; then
    pass "crAPI route OK (HTTP ${STATUS})"
else
    fail "crAPI route returned HTTP ${STATUS}"
fi

# 5. API Gateway → Juice Shop (skipped when API_GW_URL is absent)
echo ""
echo -e "${BOLD}5. API Gateway → Juice Shop route${RESET}"
if [[ -z "${API_GW_URL:-}" ]]; then
    warn "API_GW_URL not set — skipping API Gateway check"
else
    STATUS=$(curl -s -o /dev/null -w "%{http_code}" --max-time 15 \
        "${API_GW_URL}/shop/api/Products" 2>/dev/null || echo "000")
    if [[ "${STATUS}" == "200" ]]; then
        pass "API Gateway → Juice Shop OK (HTTP ${STATUS})"
    else
        fail "API Gateway returned HTTP ${STATUS} (expected 200)"
    fi
fi

# 6. Kong nonamesecurity plugin
echo ""
echo -e "${BOLD}6. Kong — nonamesecurity plugin installed${RESET}"
PLUGINS_JSON=$(curl -sf --max-time 10 "${KONG_ADMIN_URL}/plugins" 2>/dev/null || echo "")
if [[ -z "${PLUGINS_JSON}" ]]; then
    fail "Could not reach Kong Admin API at ${KONG_ADMIN_URL}"
else
    PLUGIN_NAMES=$(echo "${PLUGINS_JSON}" \
        | python3 -c "import sys,json; [print(p['name']) for p in json.load(sys.stdin)['data']]" \
        2>/dev/null || echo "")
    if echo "${PLUGIN_NAMES}" | grep -q "nonamesecurity"; then
        pass "nonamesecurity plugin is active on Kong"
    else
        fail "nonamesecurity plugin NOT found. Active plugins: $(echo "${PLUGIN_NAMES}" | tr '\n' ' ')"
    fi
fi

# 7. Kong routes
echo ""
echo -e "${BOLD}7. Kong — routes present (crapi-route, pixi-route, sample-route)${RESET}"
ROUTES_JSON=$(curl -sf --max-time 10 "${KONG_ADMIN_URL}/routes" 2>/dev/null || echo "")
if [[ -z "${ROUTES_JSON}" ]]; then
    fail "Could not reach Kong Admin API at ${KONG_ADMIN_URL}"
else
    ROUTE_NAMES=$(echo "${ROUTES_JSON}" \
        | python3 -c "import sys,json; [print(r['name']) for r in json.load(sys.stdin)['data']]" \
        2>/dev/null || echo "")
    ROUTES_MISSING=0
    for expected in crapi-route pixi-route sample-route; do
        if echo "${ROUTE_NAMES}" | grep -q "^${expected}$"; then
            info "${expected} ✓"
        else
            info "${expected} ✗  (not found)"
            ROUTES_MISSING=$((ROUTES_MISSING+1))
        fi
    done
    if [[ "${ROUTES_MISSING}" -eq 0 ]]; then
        pass "All three Kong routes present"
    else
        fail "${ROUTES_MISSING} Kong route(s) missing — run 'make provision'"
    fi
fi

# ── Summary ────────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}──────────────────────────────────────────────────────────────${RESET}"
TOTAL=$((PASS+FAIL))
if [[ "${FAIL}" -eq 0 ]]; then
    echo -e "${GREEN}${BOLD}All ${TOTAL} checks passed.${RESET}"
    echo ""
    echo "  Kong, NGINX, and lab-aws-ecs should show Online in the Noname UI"
    echo "  within 1–2 minutes once traffic starts. Run: make traffic"
else
    echo -e "${RED}${BOLD}${PASS}/${TOTAL} checks passed — see failures above.${RESET}"
    exit 1
fi
