#!/usr/bin/env bash
# ============================================================
# Matrix Homeserver Stack — Validation Script
# ============================================================
# Usage: bash validate.sh
#
# Checks configuration, environment, and data directory state.
# Exits 0 if all checks pass, 1 if any fail.
# ============================================================

set -euo pipefail

# ────────────────────────────────────────────────────────────
# Colors & helpers
# ────────────────────────────────────────────────────────────
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

PASS_COUNT=0
FAIL_COUNT=0
WARN_COUNT=0

pass() {
    echo -e "  ${GREEN}[PASS]${NC} $*"
    PASS_COUNT=$((PASS_COUNT + 1))
}

fail() {
    echo -e "  ${RED}[FAIL]${NC} $*"
    FAIL_COUNT=$((FAIL_COUNT + 1))
}

warn() {
    echo -e "  ${YELLOW}[WARN]${NC} $*"
    WARN_COUNT=$((WARN_COUNT + 1))
}

section() {
    echo ""
    echo -e "${BOLD}${CYAN}── $* ──${NC}"
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

echo ""
echo -e "${BOLD}${CYAN}Matrix Homeserver — Configuration Validation${NC}"
echo -e "${CYAN}$(date '+%Y-%m-%d %H:%M:%S')${NC}"

# ════════════════════════════════════════════════════════════
# Check 1: .env file exists and is not the example
# ════════════════════════════════════════════════════════════
section "Environment File"

if [[ -f ".env" ]]; then
    pass ".env file exists"
else
    fail ".env file not found — run: cp .env.example .env && edit .env"
fi

# Source .env for remaining checks
if [[ -f ".env" ]]; then
    set -a
    # shellcheck disable=SC1091
    source .env 2>/dev/null || true
    set +a
fi

# ════════════════════════════════════════════════════════════
# Check 2: Required variables are set and non-empty
# ════════════════════════════════════════════════════════════
section "Required Environment Variables"

check_var() {
    local var="$1"
    local value="${!var:-}"
    if [[ -z "${value}" ]]; then
        fail "${var} is not set"
    else
        pass "${var} is set"
    fi
}

REQUIRED_VARS=(
    MATRIX_SERVER_NAME
    SYNAPSE_HOSTNAME
    ELEMENT_HOSTNAME
    SYNAPSE_PUBLIC_BASEURL
    TRAEFIK_ACME_EMAIL
    POSTGRES_DB
    POSTGRES_USER
    POSTGRES_PASSWORD
    REDIS_PASSWORD
    COTURN_REALM
    COTURN_STATIC_AUTH_SECRET
    COTURN_MIN_PORT
    COTURN_MAX_PORT
    COTURN_PORT
    COTURN_TLS_PORT
    SYNAPSE_MACAROON_SECRET_KEY
    SYNAPSE_FORM_SECRET
    SYNAPSE_REGISTRATION_SHARED_SECRET
)

for var in "${REQUIRED_VARS[@]}"; do
    check_var "${var}"
done

# ════════════════════════════════════════════════════════════
# Check 3: Variable format validation
# ════════════════════════════════════════════════════════════
section "Variable Format Checks"

# MATRIX_SERVER_NAME must not start with http(s)://
if [[ -n "${MATRIX_SERVER_NAME:-}" ]]; then
    if [[ "${MATRIX_SERVER_NAME}" == http://* ]] || [[ "${MATRIX_SERVER_NAME}" == https://* ]]; then
        fail "MATRIX_SERVER_NAME must be a bare domain (e.g. example.com), not a URL. Got: ${MATRIX_SERVER_NAME}"
    else
        pass "MATRIX_SERVER_NAME does not contain scheme"
    fi

    # MATRIX_SERVER_NAME should not start with 'matrix.'
    if [[ "${MATRIX_SERVER_NAME}" == matrix.* ]]; then
        warn "MATRIX_SERVER_NAME starts with 'matrix.' — this is unusual. Matrix IDs will look like @alice:matrix.example.com"
    else
        pass "MATRIX_SERVER_NAME does not start with 'matrix.'"
    fi
fi

# SYNAPSE_PUBLIC_BASEURL must start with https://
if [[ -n "${SYNAPSE_PUBLIC_BASEURL:-}" ]]; then
    if [[ "${SYNAPSE_PUBLIC_BASEURL}" != https://* ]]; then
        fail "SYNAPSE_PUBLIC_BASEURL must start with https:// — got: ${SYNAPSE_PUBLIC_BASEURL}"
    else
        pass "SYNAPSE_PUBLIC_BASEURL starts with https://"
    fi
    # No trailing slash
    if [[ "${SYNAPSE_PUBLIC_BASEURL}" == */ ]]; then
        warn "SYNAPSE_PUBLIC_BASEURL ends with trailing slash — this may cause issues"
    else
        pass "SYNAPSE_PUBLIC_BASEURL has no trailing slash"
    fi
fi

# TRAEFIK_ACME_EMAIL should look like an email
if [[ -n "${TRAEFIK_ACME_EMAIL:-}" ]]; then
    if [[ "${TRAEFIK_ACME_EMAIL}" == *@* ]]; then
        pass "TRAEFIK_ACME_EMAIL looks like a valid email address"
    else
        fail "TRAEFIK_ACME_EMAIL does not look like an email address: ${TRAEFIK_ACME_EMAIL}"
    fi
fi

# ════════════════════════════════════════════════════════════
# Check 4: Secrets are non-empty and not placeholder values
# ════════════════════════════════════════════════════════════
section "Secret Validation"

check_secret() {
    local var="$1"
    local value="${!var:-}"

    if [[ -z "${value}" ]]; then
        fail "${var}: not set (run: bash scripts/generate-secrets.sh)"
        return
    fi

    # Check for CHANGE_ME placeholders
    if [[ "${value}" == *"CHANGE_ME"* ]]; then
        fail "${var}: still contains CHANGE_ME placeholder — set a real value"
        return
    fi

    # Check minimum length (secrets should be at least 16 chars)
    if [[ "${#value}" -lt 16 ]]; then
        warn "${var}: value looks too short (${#value} chars) — use a longer secret"
    else
        pass "${var}: set and appears valid (${#value} chars)"
    fi
}

check_secret POSTGRES_PASSWORD
check_secret REDIS_PASSWORD
check_secret SYNAPSE_MACAROON_SECRET_KEY
check_secret SYNAPSE_FORM_SECRET
check_secret SYNAPSE_REGISTRATION_SHARED_SECRET
check_secret COTURN_STATIC_AUTH_SECRET

# ════════════════════════════════════════════════════════════
# Check 5: Data directories exist
# ════════════════════════════════════════════════════════════
section "Data Directories"

for dir in data/synapse data/coturn data/well-known data/synapse/logs backups; do
    if [[ -d "${dir}" ]]; then
        pass "Directory exists: ${dir}"
    else
        fail "Directory missing: ${dir} — run: bash bootstrap.sh"
    fi
done

# ════════════════════════════════════════════════════════════
# Check 6: Processed config files exist
# ════════════════════════════════════════════════════════════
section "Processed Configuration Files"

check_file() {
    local path="$1"
    local desc="${2:-${path}}"
    if [[ -f "${path}" ]]; then
        pass "${desc} exists"
    else
        fail "${desc} not found at ${path} — run: bash scripts/init-synapse.sh"
    fi
}

check_file "data/synapse/homeserver.yaml"        "Synapse homeserver.yaml"
check_file "data/synapse/log.config"             "Synapse log.config"
check_file "data/coturn/turnserver.conf"         "Coturn turnserver.conf"
check_file "data/well-known/client"              "Well-known matrix/client"
check_file "data/well-known/server"              "Well-known matrix/server"

# Signing key
if [[ -n "${MATRIX_SERVER_NAME:-}" ]]; then
    SIGNING_KEY_PATH="data/synapse/${MATRIX_SERVER_NAME}.signing.key"
    if [[ -f "${SIGNING_KEY_PATH}" ]]; then
        pass "Synapse signing key exists: ${SIGNING_KEY_PATH}"
    else
        fail "Signing key not found: ${SIGNING_KEY_PATH} — run: bash scripts/init-synapse.sh"
    fi
fi

# ════════════════════════════════════════════════════════════
# Check 7: compose.yaml exists
# ════════════════════════════════════════════════════════════
section "Compose File"

if [[ -f "compose.yaml" ]]; then
    pass "compose.yaml exists"
else
    fail "compose.yaml not found"
fi

# ════════════════════════════════════════════════════════════
# Check 8: Docker is running
# ════════════════════════════════════════════════════════════
section "Docker"

if docker info &>/dev/null; then
    pass "Docker daemon is running"
else
    fail "Docker daemon is not running or not accessible"
fi

if docker compose version &>/dev/null; then
    COMPOSE_VERSION=$(docker compose version --short 2>/dev/null || echo "unknown")
    pass "Docker Compose plugin is available (${COMPOSE_VERSION})"
else
    fail "Docker Compose plugin not found"
fi

# ════════════════════════════════════════════════════════════
# Summary
# ════════════════════════════════════════════════════════════
echo ""
echo -e "${BOLD}──────────────────────────────────────${NC}"
echo -e "${BOLD}Validation Summary${NC}"
echo -e "  ${GREEN}PASS: ${PASS_COUNT}${NC}"
echo -e "  ${YELLOW}WARN: ${WARN_COUNT}${NC}"
echo -e "  ${RED}FAIL: ${FAIL_COUNT}${NC}"
echo -e "${BOLD}──────────────────────────────────────${NC}"
echo ""

if [[ ${FAIL_COUNT} -gt 0 ]]; then
    echo -e "${RED}${BOLD}Validation FAILED. Fix the issues above before starting the stack.${NC}"
    exit 1
else
    echo -e "${GREEN}${BOLD}Validation PASSED.${NC}"
    if [[ ${WARN_COUNT} -gt 0 ]]; then
        echo -e "${YELLOW}Review the warnings above.${NC}"
    fi
    exit 0
fi
