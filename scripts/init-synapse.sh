#!/usr/bin/env bash
# ============================================================
# Matrix Homeserver Stack — Synapse Initialization Script
# ============================================================
# Usage: bash scripts/init-synapse.sh
#
# This script:
#   1. Validates required environment variables
#   2. Creates data/synapse/ subdirectories
#   3. Processes homeserver.yaml.tpl → data/synapse/homeserver.yaml
#   4. Processes log.config.tpl → data/synapse/log.config
#   5. Generates the Synapse signing key (if not already present)
#   6. Sets correct ownership on data/synapse/
# ============================================================

set -euo pipefail

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m'

info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "${SCRIPT_DIR}")"
cd "${ROOT_DIR}"

# ────────────────────────────────────────────────────────────
# Step 1: Load and validate .env
# ────────────────────────────────────────────────────────────
if [[ ! -f ".env" ]]; then
    error ".env not found. Run: cp .env.example .env"
    exit 1
fi

set -a
# shellcheck disable=SC1091
source .env
set +a

REQUIRED_VARS=(
    MATRIX_SERVER_NAME
    SYNAPSE_HOSTNAME
    SYNAPSE_PUBLIC_BASEURL
    POSTGRES_USER
    POSTGRES_PASSWORD
    POSTGRES_DB
    REDIS_PASSWORD
    SYNAPSE_MACAROON_SECRET_KEY
    SYNAPSE_FORM_SECRET
    SYNAPSE_REGISTRATION_SHARED_SECRET
    COTURN_REALM
    COTURN_STATIC_AUTH_SECRET
    COTURN_PORT
    COTURN_TLS_PORT
    SYNAPSE_ENABLE_REGISTRATION
    SYNAPSE_ALLOW_GUEST_ACCESS
    SYNAPSE_FEDERATION_ENABLED
    SYNAPSE_MAX_UPLOAD_SIZE
)

info "Validating required environment variables..."
for var in "${REQUIRED_VARS[@]}"; do
    if [[ -z "${!var:-}" ]]; then
        error "Required variable ${var} is not set in .env"
        exit 1
    fi
done
success "All required variables are set"

# ────────────────────────────────────────────────────────────
# Step 2: Create data directories
# ────────────────────────────────────────────────────────────
info "Creating data/synapse directories..."
mkdir -p \
    data/synapse \
    data/synapse/media_store \
    data/synapse/logs
success "Directories created"

# ────────────────────────────────────────────────────────────
# Step 3: Process homeserver.yaml template
# ────────────────────────────────────────────────────────────
info "Processing config/synapse/homeserver.yaml.tpl → data/synapse/homeserver.yaml"

if [[ ! -f "config/synapse/homeserver.yaml.tpl" ]]; then
    error "Template not found: config/synapse/homeserver.yaml.tpl"
    exit 1
fi

envsubst < config/synapse/homeserver.yaml.tpl > data/synapse/homeserver.yaml
success "data/synapse/homeserver.yaml written"

# ────────────────────────────────────────────────────────────
# Step 4: Process log.config template
# ────────────────────────────────────────────────────────────
info "Processing config/synapse/log.config.tpl → data/synapse/log.config"

if [[ ! -f "config/synapse/log.config.tpl" ]]; then
    error "Template not found: config/synapse/log.config.tpl"
    exit 1
fi

envsubst < config/synapse/log.config.tpl > data/synapse/log.config
success "data/synapse/log.config written"

# ────────────────────────────────────────────────────────────
# Step 5: Generate signing key if not present
# ────────────────────────────────────────────────────────────
SIGNING_KEY_PATH="data/synapse/${MATRIX_SERVER_NAME}.signing.key"

if [[ -f "${SIGNING_KEY_PATH}" ]]; then
    success "Signing key already exists: ${SIGNING_KEY_PATH}"
else
    info "Signing key not found. Generating via Synapse container..."
    warn "This will run 'docker run matrixdotorg/synapse:latest generate'"
    warn "The generated homeserver.yaml will be overwritten by our template."

    # Pull image first (silent if already present)
    docker pull matrixdotorg/synapse:latest --quiet

    # Run Synapse generate to create the signing key and a default homeserver.yaml
    docker run --rm \
        -v "$(pwd)/data/synapse:/data" \
        -e "SYNAPSE_SERVER_NAME=${MATRIX_SERVER_NAME}" \
        -e "SYNAPSE_REPORT_STATS=no" \
        matrixdotorg/synapse:latest generate

    # The generate command overwrites homeserver.yaml with a default config.
    # Re-process our template to restore our settings:
    info "Re-processing homeserver.yaml template (overwriting generated defaults)..."
    envsubst < config/synapse/homeserver.yaml.tpl > data/synapse/homeserver.yaml
    success "homeserver.yaml restored from template"

    if [[ -f "${SIGNING_KEY_PATH}" ]]; then
        success "Signing key generated: ${SIGNING_KEY_PATH}"
    else
        error "Signing key not found after generate. Check docker run output above."
        exit 1
    fi
fi

# ────────────────────────────────────────────────────────────
# Step 6: Set ownership (Synapse runs as UID 991 in container)
# ────────────────────────────────────────────────────────────
info "Setting data/synapse ownership to 991:991..."
if chown -R 991:991 data/synapse 2>/dev/null; then
    success "Ownership set to 991:991"
else
    warn "chown failed (may need sudo)."
    if sudo chown -R 991:991 data/synapse 2>/dev/null; then
        success "Ownership set to 991:991 (via sudo)"
    else
        warn "Could not set ownership. Synapse may encounter permission errors."
        warn "Run manually: sudo chown -R 991:991 data/synapse"
    fi
fi

# ────────────────────────────────────────────────────────────
# Done
# ────────────────────────────────────────────────────────────
echo ""
success "Synapse initialization complete"
echo ""
echo "  data/synapse/homeserver.yaml      — Synapse configuration"
echo "  data/synapse/log.config           — Logging configuration"
echo "  data/synapse/${MATRIX_SERVER_NAME}.signing.key — Server signing key"
echo ""
echo -e "${CYAN}Next step: docker compose up -d${NC}"
echo ""
