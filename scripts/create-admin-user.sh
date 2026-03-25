#!/usr/bin/env bash
# ============================================================
# Matrix Homeserver Stack — Create Admin User
# ============================================================
# Usage: bash scripts/create-admin-user.sh [username]
#
# Creates a Matrix admin user using the registration shared
# secret (does not require open registration to be enabled).
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
# Load .env
# ────────────────────────────────────────────────────────────
if [[ ! -f ".env" ]]; then
    error ".env not found."
    exit 1
fi
set -a
# shellcheck disable=SC1091
source .env
set +a

# ────────────────────────────────────────────────────────────
# Check synapse container is running
# ────────────────────────────────────────────────────────────
info "Checking Synapse container status..."

if ! docker compose ps synapse 2>/dev/null | grep -q "running"; then
    # Check with 'Up' (older compose format)
    if ! docker compose ps synapse 2>/dev/null | grep -qi "up\|running\|healthy"; then
        error "Synapse container is not running."
        error "Start it with: docker compose up -d synapse"
        exit 1
    fi
fi

# Quick health check
if ! docker compose exec -T synapse curl -fsSL http://localhost:8008/health &>/dev/null; then
    error "Synapse health endpoint is not responding."
    error "Check logs: docker compose logs synapse"
    exit 1
fi

success "Synapse is running and healthy"

# ────────────────────────────────────────────────────────────
# Get username
# ────────────────────────────────────────────────────────────
if [[ $# -ge 1 ]] && [[ -n "$1" ]]; then
    ADMIN_USERNAME="$1"
else
    echo ""
    read -r -p "Enter admin username (e.g. admin): " ADMIN_USERNAME
    if [[ -z "${ADMIN_USERNAME}" ]]; then
        error "Username cannot be empty."
        exit 1
    fi
fi

# Validate username: lowercase, alphanumeric, hyphens, underscores
if ! echo "${ADMIN_USERNAME}" | grep -qE '^[a-z0-9_.-]+$'; then
    error "Username must contain only lowercase letters, numbers, underscores, hyphens, or dots."
    exit 1
fi

info "Creating admin user: @${ADMIN_USERNAME}:${MATRIX_SERVER_NAME}"

# ────────────────────────────────────────────────────────────
# Get password (with confirmation)
# ────────────────────────────────────────────────────────────
while true; do
    echo ""
    read -r -s -p "Enter password (min 8 characters): " ADMIN_PASSWORD
    echo ""

    if [[ ${#ADMIN_PASSWORD} -lt 8 ]]; then
        warn "Password must be at least 8 characters. Try again."
        continue
    fi

    read -r -s -p "Confirm password: " ADMIN_PASSWORD_CONFIRM
    echo ""

    if [[ "${ADMIN_PASSWORD}" != "${ADMIN_PASSWORD_CONFIRM}" ]]; then
        warn "Passwords do not match. Try again."
        continue
    fi

    break
done

# ────────────────────────────────────────────────────────────
# Create the admin user
# ────────────────────────────────────────────────────────────
echo ""
info "Registering admin user..."

docker compose exec -T synapse \
    register_new_matrix_user \
    -c /data/homeserver.yaml \
    --admin \
    -u "${ADMIN_USERNAME}" \
    -p "${ADMIN_PASSWORD}" \
    http://localhost:8008

# ────────────────────────────────────────────────────────────
# Success
# ────────────────────────────────────────────────────────────
echo ""
success "Admin user created successfully!"
echo ""
echo "  Matrix ID:  @${ADMIN_USERNAME}:${MATRIX_SERVER_NAME}"
echo "  Login URL:  https://${ELEMENT_HOSTNAME}"
echo ""
echo "  To log in:"
echo "    1. Open https://${ELEMENT_HOSTNAME}"
echo "    2. Click 'Sign In'"
echo "    3. Set homeserver to: ${SYNAPSE_PUBLIC_BASEURL}"
echo "    4. Enter username: ${ADMIN_USERNAME}"
echo "    5. Enter the password you just set"
echo ""
echo -e "${CYAN}Tip: You can also manage users via the Synapse Admin API:${NC}"
echo "  curl -H 'Authorization: Bearer <access_token>' \\"
echo "       ${SYNAPSE_PUBLIC_BASEURL}/_synapse/admin/v2/users/@${ADMIN_USERNAME}:${MATRIX_SERVER_NAME}"
echo ""
