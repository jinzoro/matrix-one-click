#!/usr/bin/env bash
# ============================================================
# Matrix Homeserver Stack — Secret Generator
# ============================================================
# Usage: bash scripts/generate-secrets.sh
#
# Generates cryptographic secrets and writes them into .env.
# Already-set secrets are NOT overwritten.
# ============================================================

set -euo pipefail

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "${SCRIPT_DIR}")"
cd "${ROOT_DIR}"

if [[ ! -f ".env" ]]; then
    echo "Error: .env not found. Run: cp .env.example .env" >&2
    exit 1
fi

# ────────────────────────────────────────────────────────────
# Helper: update a key's value in .env
# update_env KEY VALUE
# Uses sed to replace the line KEY= in .env.
# ────────────────────────────────────────────────────────────
update_env() {
    local key="$1"
    local value="$2"
    local env_file="${ROOT_DIR}/.env"

    if grep -q "^${key}=" "${env_file}"; then
        # Replace existing line (escape special chars in value for sed)
        local escaped_value
        escaped_value=$(printf '%s\n' "${value}" | sed -e 's/[\/&]/\\&/g')
        sed -i "s|^${key}=.*|${key}=${escaped_value}|" "${env_file}"
    else
        # Append if key doesn't exist
        echo "${key}=${value}" >> "${env_file}"
    fi
}

# ────────────────────────────────────────────────────────────
# Load current .env values
# ────────────────────────────────────────────────────────────
set -a
# shellcheck disable=SC1091
source .env
set +a

GENERATED_KEYS=()
SKIPPED_KEYS=()

# ────────────────────────────────────────────────────────────
# Generate SYNAPSE_MACAROON_SECRET_KEY
# ────────────────────────────────────────────────────────────
if [[ -z "${SYNAPSE_MACAROON_SECRET_KEY:-}" ]]; then
    NEW_SECRET=$(openssl rand -base64 48 | tr -d '\n')
    update_env "SYNAPSE_MACAROON_SECRET_KEY" "${NEW_SECRET}"
    GENERATED_KEYS+=("SYNAPSE_MACAROON_SECRET_KEY")
    success "Generated SYNAPSE_MACAROON_SECRET_KEY"
else
    SKIPPED_KEYS+=("SYNAPSE_MACAROON_SECRET_KEY")
    info "SYNAPSE_MACAROON_SECRET_KEY already set — skipping"
fi

# ────────────────────────────────────────────────────────────
# Generate SYNAPSE_FORM_SECRET
# ────────────────────────────────────────────────────────────
if [[ -z "${SYNAPSE_FORM_SECRET:-}" ]]; then
    NEW_SECRET=$(openssl rand -base64 48 | tr -d '\n')
    update_env "SYNAPSE_FORM_SECRET" "${NEW_SECRET}"
    GENERATED_KEYS+=("SYNAPSE_FORM_SECRET")
    success "Generated SYNAPSE_FORM_SECRET"
else
    SKIPPED_KEYS+=("SYNAPSE_FORM_SECRET")
    info "SYNAPSE_FORM_SECRET already set — skipping"
fi

# ────────────────────────────────────────────────────────────
# Generate SYNAPSE_REGISTRATION_SHARED_SECRET
# ────────────────────────────────────────────────────────────
if [[ -z "${SYNAPSE_REGISTRATION_SHARED_SECRET:-}" ]]; then
    NEW_SECRET=$(openssl rand -base64 48 | tr -d '\n')
    update_env "SYNAPSE_REGISTRATION_SHARED_SECRET" "${NEW_SECRET}"
    GENERATED_KEYS+=("SYNAPSE_REGISTRATION_SHARED_SECRET")
    success "Generated SYNAPSE_REGISTRATION_SHARED_SECRET"
else
    SKIPPED_KEYS+=("SYNAPSE_REGISTRATION_SHARED_SECRET")
    info "SYNAPSE_REGISTRATION_SHARED_SECRET already set — skipping"
fi

# ────────────────────────────────────────────────────────────
# Generate COTURN_STATIC_AUTH_SECRET (if placeholder)
# ────────────────────────────────────────────────────────────
if [[ "${COTURN_STATIC_AUTH_SECRET:-}" == "CHANGE_ME_coturn_secret" ]] || [[ -z "${COTURN_STATIC_AUTH_SECRET:-}" ]]; then
    NEW_SECRET=$(openssl rand -base64 48 | tr -d '\n')
    update_env "COTURN_STATIC_AUTH_SECRET" "${NEW_SECRET}"
    GENERATED_KEYS+=("COTURN_STATIC_AUTH_SECRET")
    success "Generated COTURN_STATIC_AUTH_SECRET"
else
    SKIPPED_KEYS+=("COTURN_STATIC_AUTH_SECRET")
    info "COTURN_STATIC_AUTH_SECRET already set — skipping"
fi

# ────────────────────────────────────────────────────────────
# Generate REDIS_PASSWORD (if placeholder)
# ────────────────────────────────────────────────────────────
if [[ "${REDIS_PASSWORD:-}" == "CHANGE_ME_redis_password" ]] || [[ -z "${REDIS_PASSWORD:-}" ]]; then
    NEW_SECRET=$(openssl rand -base64 32 | tr -d '\n/+=' | head -c 32)
    update_env "REDIS_PASSWORD" "${NEW_SECRET}"
    GENERATED_KEYS+=("REDIS_PASSWORD")
    success "Generated REDIS_PASSWORD"
else
    SKIPPED_KEYS+=("REDIS_PASSWORD")
    info "REDIS_PASSWORD already set — skipping"
fi

# ────────────────────────────────────────────────────────────
# Summary
# ────────────────────────────────────────────────────────────
echo ""
if [[ ${#GENERATED_KEYS[@]} -gt 0 ]]; then
    echo -e "${GREEN}Secrets generated and written to .env:${NC}"
    for key in "${GENERATED_KEYS[@]}"; do
        echo -e "  ${GREEN}+${NC} ${key}"
    done
fi

if [[ ${#SKIPPED_KEYS[@]} -gt 0 ]]; then
    echo -e "${YELLOW}Secrets already set (skipped):${NC}"
    for key in "${SKIPPED_KEYS[@]}"; do
        echo -e "  ${YELLOW}~${NC} ${key}"
    done
fi

echo ""
echo -e "${CYAN}Next step: bash scripts/init-synapse.sh${NC}"
echo ""
