#!/usr/bin/env bash
# ============================================================
# Matrix Homeserver Stack — Upgrade Script
# ============================================================
# Usage: bash upgrade.sh
#
# This script performs a safe upgrade of all services:
#   1. Print upgrade warning
#   2. Prompt for confirmation
#   3. Run backup first
#   4. Pull new images
#   5. Recreate services in correct dependency order
#   6. Wait for health checks
#   7. Show running containers
#   8. Print post-upgrade checks
# ============================================================

set -euo pipefail

# ────────────────────────────────────────────────────────────
# Colors & helpers
# ────────────────────────────────────────────────────────────
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
step()    { echo -e "\n${BOLD}${CYAN}══ $* ══${NC}"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

# ────────────────────────────────────────────────────────────
# Load .env
# ────────────────────────────────────────────────────────────
if [[ ! -f ".env" ]]; then
    error ".env not found. Run bootstrap.sh first."
    exit 1
fi
set -a
# shellcheck disable=SC1091
source .env
set +a

# ════════════════════════════════════════════════════════════
# STEP 1: Warning and confirmation
# ════════════════════════════════════════════════════════════
echo ""
echo -e "${YELLOW}${BOLD}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${YELLOW}${BOLD}║              Matrix Homeserver Upgrade                   ║${NC}"
echo -e "${YELLOW}${BOLD}╚══════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${YELLOW}This script will:${NC}"
echo "  1. Create a backup of your database and media"
echo "  2. Pull the latest Docker images"
echo "  3. Recreate each service in order"
echo "  4. Run database migrations (Synapse does this automatically)"
echo ""
echo -e "${YELLOW}${BOLD}IMPORTANT:${NC} Check the Synapse changelog before upgrading!"
echo "  https://github.com/element-hq/synapse/blob/master/CHANGES.md"
echo ""
echo -e "${YELLOW}There will be a brief downtime while services are being recreated.${NC}"
echo ""
read -r -p "Press ENTER to continue, or Ctrl+C to abort: "

# ════════════════════════════════════════════════════════════
# STEP 2: Pre-upgrade backup
# ════════════════════════════════════════════════════════════
step "Step 2: Running pre-upgrade backup"

info "Creating backup before upgrade..."
if bash scripts/backup.sh; then
    success "Backup completed"
else
    error "Backup failed! Aborting upgrade."
    error "Fix the backup issue or manually back up data/synapse and run pg_dump."
    exit 1
fi

# ════════════════════════════════════════════════════════════
# STEP 3: Pull new images
# ════════════════════════════════════════════════════════════
step "Step 3: Pulling latest images"

info "Pulling all images..."
docker compose pull
success "All images pulled"

# Print image digest info for audit trail
echo ""
info "New image versions:"
docker compose images
echo ""

# ════════════════════════════════════════════════════════════
# STEP 4: Recreate services in order
# ════════════════════════════════════════════════════════════
step "Step 4: Recreating services"

# ── Postgres (upgrade in-place; no schema changes needed from Docker side) ──
info "Upgrading postgres..."
docker compose stop postgres
docker compose up -d --no-deps postgres

info "Waiting for postgres to be healthy..."
MAX_WAIT=60
elapsed=0
while ! docker compose exec -T postgres pg_isready -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" &>/dev/null; do
    if [[ ${elapsed} -ge ${MAX_WAIT} ]]; then
        error "Postgres did not recover within ${MAX_WAIT} seconds."
        exit 1
    fi
    sleep 5; elapsed=$((elapsed + 5))
done
success "Postgres is healthy"

# ── Redis ─────────────────────────────────────────────────────
info "Upgrading redis..."
docker compose stop redis
docker compose up -d --no-deps redis
sleep 5
success "Redis restarted"

# ── Synapse — most critical, runs migrations on start ─────────
info "Upgrading Synapse..."
warn "Synapse will be unavailable for a short time while it runs DB migrations."
docker compose stop synapse

# Small delay to ensure clean stop
sleep 3

docker compose up -d --no-deps synapse

info "Waiting for Synapse to complete migrations and become healthy..."
MAX_WAIT=180
WAIT_INTERVAL=5
elapsed=0
while ! docker compose exec -T synapse curl -fsSL http://localhost:8008/health &>/dev/null; do
    if [[ ${elapsed} -ge ${MAX_WAIT} ]]; then
        error "Synapse did not become healthy within ${MAX_WAIT} seconds."
        error "Check logs: docker compose logs synapse"
        docker compose logs --tail=50 synapse
        exit 1
    fi
    info "Waiting for Synapse health... (${elapsed}s elapsed)"
    sleep "${WAIT_INTERVAL}"
    elapsed=$((elapsed + WAIT_INTERVAL))
done
success "Synapse is healthy"

# ── Element Web ───────────────────────────────────────────────
info "Upgrading Element Web..."
docker compose stop element-web
docker compose up -d --no-deps element-web
success "Element Web restarted"

# ── Traefik ───────────────────────────────────────────────────
info "Upgrading Traefik..."
docker compose stop traefik
docker compose up -d --no-deps traefik

info "Waiting for Traefik ping..."
sleep 10
MAX_WAIT=30
elapsed=0
while ! docker compose exec -T traefik wget --no-verbose --tries=1 --spider http://localhost:80/ping &>/dev/null; do
    if [[ ${elapsed} -ge ${MAX_WAIT} ]]; then
        warn "Traefik ping did not respond, but continuing (may still be acquiring certs)."
        break
    fi
    sleep 5; elapsed=$((elapsed + 5))
done
success "Traefik is up"

# ── Coturn ────────────────────────────────────────────────────
info "Upgrading Coturn..."
docker compose stop coturn
docker compose up -d --no-deps coturn
success "Coturn restarted"

# ── Well-known ────────────────────────────────────────────────
info "Upgrading well-known nginx..."
docker compose stop well-known
docker compose up -d --no-deps well-known
success "Well-known restarted"

# ════════════════════════════════════════════════════════════
# STEP 5: Show status
# ════════════════════════════════════════════════════════════
step "Step 5: Final status"

docker compose ps

# ════════════════════════════════════════════════════════════
# Done!
# ════════════════════════════════════════════════════════════
echo ""
echo -e "${GREEN}${BOLD}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}${BOLD}║           Upgrade Completed Successfully!                ║${NC}"
echo -e "${GREEN}${BOLD}╚══════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  ${BOLD}Post-upgrade checks to run:${NC}"
echo ""
echo "  1. Verify services are healthy:"
echo "       make status"
echo ""
echo "  2. Check Synapse is reachable:"
echo "       curl -fsSL ${SYNAPSE_PUBLIC_BASEURL}/_matrix/client/versions | jq '.versions'"
echo ""
echo "  3. Verify federation still works:"
echo "       make check-federation"
echo ""
echo "  4. Check well-known endpoints:"
echo "       make check-well-known"
echo ""
echo "  5. Review Synapse logs for any errors:"
echo "       make logs-synapse"
echo ""
echo -e "  ${CYAN}If something went wrong, restore from the pre-upgrade backup:${NC}"
echo "       make restore BACKUP_DIR=backups/<timestamp>"
echo ""
