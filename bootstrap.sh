#!/usr/bin/env bash
# ============================================================
# Matrix Homeserver Stack — Bootstrap Script
# ============================================================
# Usage: bash bootstrap.sh
#
# This script performs the full first-time setup:
#   1. Check prerequisites
#   2. Validate .env file
#   3. Generate secrets (if not already done)
#   4. Create data directories
#   5. Process config templates
#   6. Set permissions
#   7. Initialize Synapse (signing key, DB migrations)
#   8. Start the stack
#   9. Wait for health checks
#  10. Print success message
# ============================================================

set -euo pipefail

# ────────────────────────────────────────────────────────────
# Colors & logging helpers
# ────────────────────────────────────────────────────────────
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
step()    { echo -e "\n${BOLD}${CYAN}══ $* ══${NC}"; }

# ────────────────────────────────────────────────────────────
# Resolve script directory (works when called from any cwd)
# ────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

# ════════════════════════════════════════════════════════════
# STEP 1: Check prerequisites
# ════════════════════════════════════════════════════════════
step "Step 1: Checking prerequisites"

check_command() {
    local cmd="$1"
    local install_hint="${2:-}"
    if ! command -v "${cmd}" &>/dev/null; then
        error "Required command not found: ${cmd}"
        if [[ -n "${install_hint}" ]]; then
            error "Install hint: ${install_hint}"
        fi
        exit 1
    fi
    success "${cmd} found: $(command -v "${cmd}")"
}

check_command docker      "https://docs.docker.com/engine/install/"
check_command curl        "apt install curl / yum install curl"
check_command openssl     "apt install openssl / yum install openssl"
check_command envsubst    "apt install gettext / yum install gettext"

# Check Docker Compose plugin (not standalone docker-compose)
if ! docker compose version &>/dev/null; then
    error "Docker Compose plugin not found."
    error "Install: https://docs.docker.com/compose/install/"
    exit 1
fi
success "docker compose plugin found"

# Check Docker daemon is running
if ! docker info &>/dev/null; then
    error "Docker daemon is not running or current user lacks permission."
    error "Try: sudo systemctl start docker  OR  sudo usermod -aG docker \$USER"
    exit 1
fi
success "Docker daemon is running"

# ════════════════════════════════════════════════════════════
# STEP 2: Check .env file
# ════════════════════════════════════════════════════════════
step "Step 2: Checking .env file"

if [[ ! -f ".env" ]]; then
    error ".env file not found."
    error "Run the following to create it:"
    echo ""
    echo "    cp .env.example .env"
    echo "    nano .env    # fill in your domain, email, and passwords"
    echo ""
    exit 1
fi

# Make sure it's not the unmodified example
if grep -q "CHANGE_ME_strong_db_password" .env; then
    warn "POSTGRES_PASSWORD still contains the default placeholder value."
    warn "Please edit .env and set a real password before continuing."
    exit 1
fi

success ".env file found"

# Source .env
set -a
# shellcheck disable=SC1091
source .env
set +a

# ════════════════════════════════════════════════════════════
# STEP 3: Validate required variables
# ════════════════════════════════════════════════════════════
step "Step 3: Validating required variables"

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
)

VALIDATION_FAILED=false
for var in "${REQUIRED_VARS[@]}"; do
    value="${!var:-}"
    if [[ -z "${value}" ]]; then
        error "Required variable ${var} is not set in .env"
        VALIDATION_FAILED=true
    else
        success "${var} is set"
    fi
done

if [[ "${VALIDATION_FAILED}" == "true" ]]; then
    error "Fix the above variables in .env before continuing."
    exit 1
fi

# Validate SYNAPSE_PUBLIC_BASEURL starts with https://
if [[ "${SYNAPSE_PUBLIC_BASEURL}" != https://* ]]; then
    error "SYNAPSE_PUBLIC_BASEURL must start with https://"
    error "Current value: ${SYNAPSE_PUBLIC_BASEURL}"
    exit 1
fi

# Validate MATRIX_SERVER_NAME doesn't include a scheme
if [[ "${MATRIX_SERVER_NAME}" == http://* ]] || [[ "${MATRIX_SERVER_NAME}" == https://* ]]; then
    error "MATRIX_SERVER_NAME must be a bare domain (e.g. example.com), not a URL."
    exit 1
fi

success "All required variables validated"

# ════════════════════════════════════════════════════════════
# STEP 4: Generate secrets if not already set
# ════════════════════════════════════════════════════════════
step "Step 4: Checking Synapse secrets"

if [[ -z "${SYNAPSE_MACAROON_SECRET_KEY:-}" ]]; then
    warn "SYNAPSE_MACAROON_SECRET_KEY is not set. Running secret generator..."
    bash scripts/generate-secrets.sh
    # Re-source .env to pick up generated secrets
    set -a
    # shellcheck disable=SC1091
    source .env
    set +a
    success "Secrets generated"
else
    success "Secrets already present"
fi

# ════════════════════════════════════════════════════════════
# STEP 5: Create data directories
# ════════════════════════════════════════════════════════════
step "Step 5: Creating data directories"

mkdir -p \
    data/synapse \
    data/synapse/media_store \
    data/synapse/logs \
    data/coturn \
    data/well-known \
    backups

success "Data directories created"

# ════════════════════════════════════════════════════════════
# STEP 6: Process config templates
# ════════════════════════════════════════════════════════════
step "Step 6: Processing configuration templates"

# ── Synapse homeserver.yaml ──────────────────────────────────
info "Processing config/synapse/homeserver.yaml.tpl → data/synapse/homeserver.yaml"
envsubst < config/synapse/homeserver.yaml.tpl > data/synapse/homeserver.yaml
success "data/synapse/homeserver.yaml written"

# ── Synapse log.config ────────────────────────────────────────
info "Processing config/synapse/log.config.tpl → data/synapse/log.config"
envsubst < config/synapse/log.config.tpl > data/synapse/log.config
success "data/synapse/log.config written"

# ── Coturn turnserver.conf ────────────────────────────────────
info "Processing config/coturn/turnserver.conf.tpl → data/coturn/turnserver.conf"

# Determine relay IP
COTURN_RELAY_IP="${COTURN_EXTERNAL_IP:-detect}"
if [[ "${COTURN_RELAY_IP}" == "detect" ]]; then
    info "Auto-detecting external IP..."
    COTURN_RELAY_IP=$(curl -fsSL --max-time 10 https://ifconfig.me 2>/dev/null || \
                     curl -fsSL --max-time 10 https://api.ipify.org 2>/dev/null || \
                     curl -fsSL --max-time 10 https://checkip.amazonaws.com 2>/dev/null | tr -d '[:space:]')
    if [[ -z "${COTURN_RELAY_IP}" ]]; then
        error "Failed to auto-detect external IP. Set COTURN_EXTERNAL_IP explicitly in .env."
        exit 1
    fi
    info "Detected external IP: ${COTURN_RELAY_IP}"
fi
export COTURN_RELAY_IP

sed \
    -e "s|%%COTURN_PORT%%|${COTURN_PORT:-3478}|g" \
    -e "s|%%COTURN_TLS_PORT%%|${COTURN_TLS_PORT:-5349}|g" \
    -e "s|%%COTURN_RELAY_IP%%|${COTURN_RELAY_IP}|g" \
    -e "s|%%COTURN_MIN_PORT%%|${COTURN_MIN_PORT:-49152}|g" \
    -e "s|%%COTURN_MAX_PORT%%|${COTURN_MAX_PORT:-65535}|g" \
    -e "s|%%COTURN_STATIC_AUTH_SECRET%%|${COTURN_STATIC_AUTH_SECRET}|g" \
    -e "s|%%COTURN_REALM%%|${COTURN_REALM}|g" \
    config/coturn/turnserver.conf.tpl > data/coturn/turnserver.conf

success "data/coturn/turnserver.conf written"

# ── Well-known matrix/client ──────────────────────────────────
info "Processing config/well-known/matrix-client.json → data/well-known/client"
sed \
    -e "s|%%SYNAPSE_PUBLIC_BASEURL%%|${SYNAPSE_PUBLIC_BASEURL}|g" \
    config/well-known/matrix-client.json > data/well-known/client
success "data/well-known/client written"

# ── Well-known matrix/server ──────────────────────────────────
info "Processing config/well-known/matrix-server.json → data/well-known/server"
sed \
    -e "s|%%SYNAPSE_HOSTNAME%%|${SYNAPSE_HOSTNAME}|g" \
    config/well-known/matrix-server.json > data/well-known/server
success "data/well-known/server written"

# ── Element config.json ───────────────────────────────────────
info "Processing config/element/config.json (replacing placeholders)"
sed \
    -e "s|SYNAPSE_PUBLIC_BASEURL_PLACEHOLDER|${SYNAPSE_PUBLIC_BASEURL}|g" \
    -e "s|MATRIX_SERVER_NAME_PLACEHOLDER|${MATRIX_SERVER_NAME}|g" \
    -e "s|ELEMENT_HOSTNAME_PLACEHOLDER|${ELEMENT_HOSTNAME}|g" \
    config/element/config.json > /tmp/element-config-processed.json
cp /tmp/element-config-processed.json config/element/config.json
success "config/element/config.json updated"

# ════════════════════════════════════════════════════════════
# STEP 7: Set permissions on data/synapse
# ════════════════════════════════════════════════════════════
step "Step 7: Setting data directory permissions"

# Synapse runs as UID 991 / GID 991 inside the container
info "Setting data/synapse ownership to 991:991 (Synapse container user)"
if chown -R 991:991 data/synapse 2>/dev/null; then
    success "data/synapse permissions set"
else
    warn "chown failed (may need sudo). Trying with sudo..."
    if sudo chown -R 991:991 data/synapse; then
        success "data/synapse permissions set (via sudo)"
    else
        warn "Could not set ownership. Synapse may fail if the directory is not writable."
        warn "Run manually: sudo chown -R 991:991 data/synapse"
    fi
fi

# ════════════════════════════════════════════════════════════
# STEP 8: Initialize Synapse (signing key generation)
# ════════════════════════════════════════════════════════════
step "Step 8: Initializing Synapse (signing key)"

bash scripts/init-synapse.sh

# ════════════════════════════════════════════════════════════
# STEP 9: Start postgres and redis, then full stack
# ════════════════════════════════════════════════════════════
step "Step 9: Starting the stack"

info "Starting postgres and redis first..."
docker compose up -d postgres redis

info "Waiting for postgres to be healthy..."
MAX_WAIT=60
WAIT_INTERVAL=5
elapsed=0
while ! docker compose exec -T postgres pg_isready -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" &>/dev/null; do
    if [[ ${elapsed} -ge ${MAX_WAIT} ]]; then
        error "Postgres did not become healthy within ${MAX_WAIT} seconds."
        docker compose logs postgres
        exit 1
    fi
    info "Waiting for postgres... (${elapsed}s elapsed)"
    sleep "${WAIT_INTERVAL}"
    elapsed=$((elapsed + WAIT_INTERVAL))
done
success "Postgres is healthy"

info "Starting full stack..."
docker compose up -d

# ════════════════════════════════════════════════════════════
# STEP 10: Wait for Synapse to become healthy
# ════════════════════════════════════════════════════════════
step "Step 10: Waiting for Synapse to be ready"

MAX_WAIT=120
WAIT_INTERVAL=5
elapsed=0
info "Waiting for Synapse health endpoint..."
while ! docker compose exec -T synapse curl -fsSL http://localhost:8008/health &>/dev/null; do
    if [[ ${elapsed} -ge ${MAX_WAIT} ]]; then
        error "Synapse did not become healthy within ${MAX_WAIT} seconds."
        error "Check logs with: docker compose logs synapse"
        docker compose logs --tail=50 synapse
        exit 1
    fi
    info "Waiting for Synapse... (${elapsed}s elapsed)"
    sleep "${WAIT_INTERVAL}"
    elapsed=$((elapsed + WAIT_INTERVAL))
done
success "Synapse is healthy"

# ════════════════════════════════════════════════════════════
# Done!
# ════════════════════════════════════════════════════════════
echo ""
echo -e "${GREEN}${BOLD}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}${BOLD}║        Matrix Homeserver Bootstrap Complete!             ║${NC}"
echo -e "${GREEN}${BOLD}╚══════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  ${BOLD}Element Web:${NC}  https://${ELEMENT_HOSTNAME}"
echo -e "  ${BOLD}Synapse:${NC}      ${SYNAPSE_PUBLIC_BASEURL}"
echo -e "  ${BOLD}Identity:${NC}     ${MATRIX_SERVER_NAME}"
echo ""
echo -e "  ${CYAN}Next step: Create your first admin user${NC}"
echo -e "    make create-admin"
echo -e "    -- or --"
echo -e "    bash scripts/create-admin-user.sh"
echo ""
echo -e "  ${CYAN}Verify federation:${NC}  make check-federation"
echo -e "  ${CYAN}Check well-known:${NC}   make check-well-known"
echo -e "  ${CYAN}View logs:${NC}          make logs"
echo ""
