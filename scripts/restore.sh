#!/usr/bin/env bash
# ============================================================
# Matrix Homeserver Stack — Restore Script
# ============================================================
# Usage: bash scripts/restore.sh <BACKUP_DIR>
#
# Example: bash scripts/restore.sh backups/20250101_030000
#
# WARNING: This script is DESTRUCTIVE.
# It will overwrite your current database and media store.
# ============================================================

set -euo pipefail

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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "${SCRIPT_DIR}")"
cd "${ROOT_DIR}"

# ────────────────────────────────────────────────────────────
# Usage check
# ────────────────────────────────────────────────────────────
if [[ $# -lt 1 ]] || [[ -z "$1" ]]; then
    error "Usage: bash scripts/restore.sh <BACKUP_DIR>"
    error "Example: bash scripts/restore.sh backups/20250101_030000"
    exit 1
fi

BACKUP_DIR="$1"

# Handle both absolute and relative paths
if [[ "${BACKUP_DIR}" != /* ]]; then
    BACKUP_DIR="${ROOT_DIR}/${BACKUP_DIR}"
fi

if [[ ! -d "${BACKUP_DIR}" ]]; then
    error "Backup directory not found: ${BACKUP_DIR}"
    exit 1
fi

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
# Large warning
# ────────────────────────────────────────────────────────────
echo ""
echo -e "${RED}${BOLD}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${RED}${BOLD}║              ⚠  DESTRUCTIVE OPERATION ⚠                 ║${NC}"
echo -e "${RED}${BOLD}╚══════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${RED}This restore operation will:${NC}"
echo "  1. STOP the Synapse service"
echo "  2. DROP and recreate the PostgreSQL database"
echo "  3. OVERWRITE Synapse config and signing key"
echo "  4. REPLACE the media store volume"
echo ""
echo -e "${RED}Backup directory: ${BACKUP_DIR}${NC}"
echo ""
echo -e "${YELLOW}If you have a recent backup that is NOT the one being restored,${NC}"
echo -e "${YELLOW}you should take one now: bash scripts/backup.sh${NC}"
echo ""
read -r -p "Type 'RESTORE' to confirm this destructive operation: " confirm
if [[ "${confirm}" != "RESTORE" ]]; then
    echo "Aborted. No changes made."
    exit 0
fi

# ────────────────────────────────────────────────────────────
# Identify backup files
# ────────────────────────────────────────────────────────────
PG_DUMP=$(find "${BACKUP_DIR}" -name "postgres_*.sql.gz" | head -1)
CONFIG_ARCHIVE=$(find "${BACKUP_DIR}" -name "synapse_config_*.tar.gz" | head -1)
MEDIA_ARCHIVE=$(find "${BACKUP_DIR}" -name "synapse_media_*.tar.gz" | head -1)

if [[ -z "${PG_DUMP}" ]]; then
    error "No PostgreSQL dump found in ${BACKUP_DIR}"
    exit 1
fi

info "Restoring from: ${BACKUP_DIR}"
info "  Database: $(basename "${PG_DUMP}")"
[[ -n "${CONFIG_ARCHIVE}" ]] && info "  Config:   $(basename "${CONFIG_ARCHIVE}")"
[[ -n "${MEDIA_ARCHIVE}" ]]  && info "  Media:    $(basename "${MEDIA_ARCHIVE}")"
echo ""

# ────────────────────────────────────────────────────────────
# Step 1: Stop Synapse
# ────────────────────────────────────────────────────────────
info "Stopping Synapse..."
docker compose stop synapse
success "Synapse stopped"

# ────────────────────────────────────────────────────────────
# Step 2: Restore PostgreSQL
# ────────────────────────────────────────────────────────────
info "Restoring PostgreSQL database..."

# Ensure postgres is running
if ! docker compose ps postgres 2>/dev/null | grep -qi "up\|running\|healthy"; then
    info "Starting postgres..."
    docker compose up -d postgres
    sleep 10
fi

# Wait for postgres to be healthy
MAX_WAIT=30
elapsed=0
while ! docker compose exec -T postgres pg_isready -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" &>/dev/null; do
    if [[ ${elapsed} -ge ${MAX_WAIT} ]]; then
        error "PostgreSQL did not become ready in time."
        exit 1
    fi
    sleep 5; elapsed=$((elapsed + 5))
done

# Drop and recreate the database
info "Dropping and recreating database ${POSTGRES_DB}..."
docker compose exec -T postgres psql -U "${POSTGRES_USER}" postgres << EOF
SELECT pg_terminate_backend(pid)
FROM pg_stat_activity
WHERE datname = '${POSTGRES_DB}' AND pid <> pg_backend_pid();
DROP DATABASE IF EXISTS ${POSTGRES_DB};
CREATE DATABASE ${POSTGRES_DB}
  ENCODING 'UTF8'
  LC_COLLATE 'C'
  LC_CTYPE 'C'
  TEMPLATE template0;
GRANT ALL PRIVILEGES ON DATABASE ${POSTGRES_DB} TO ${POSTGRES_USER};
EOF

success "Database recreated"

# Restore from dump
info "Restoring database from dump..."
gunzip -c "${PG_DUMP}" | docker compose exec -T postgres \
    psql -U "${POSTGRES_USER}" "${POSTGRES_DB}"

success "PostgreSQL database restored"

# ────────────────────────────────────────────────────────────
# Step 3: Restore Synapse config and signing key
# ────────────────────────────────────────────────────────────
if [[ -n "${CONFIG_ARCHIVE}" ]]; then
    info "Restoring Synapse configuration..."
    tar -xzf "${CONFIG_ARCHIVE}"
    success "Synapse configuration restored"

    # Fix ownership
    chown -R 991:991 data/synapse 2>/dev/null || sudo chown -R 991:991 data/synapse || true
    success "Ownership set to 991:991"
else
    warn "No config archive found — skipping config restore"
fi

# ────────────────────────────────────────────────────────────
# Step 4: Restore media store
# ────────────────────────────────────────────────────────────
if [[ -n "${MEDIA_ARCHIVE}" ]]; then
    info "Restoring Synapse media store..."

    # Remove existing media volume data
    docker run --rm \
        -v matrix-synapse-media:/data/media_store \
        alpine \
        sh -c "rm -rf /data/media_store/* /data/media_store/.*" 2>/dev/null || true

    # Restore from archive
    docker run --rm \
        -v matrix-synapse-media:/data/media_store \
        -v "${MEDIA_ARCHIVE}:/backup/media.tar.gz:ro" \
        alpine \
        sh -c "tar -xzf /backup/media.tar.gz -C / --strip-components=0"

    success "Media store restored"
else
    warn "No media archive found — skipping media restore"
fi

# ────────────────────────────────────────────────────────────
# Step 5: Start Synapse
# ────────────────────────────────────────────────────────────
info "Starting Synapse..."
docker compose start synapse

# Wait for Synapse to be healthy
info "Waiting for Synapse to be ready..."
MAX_WAIT=120
elapsed=0
while ! docker compose exec -T synapse curl -fsSL http://localhost:8008/health &>/dev/null; do
    if [[ ${elapsed} -ge ${MAX_WAIT} ]]; then
        error "Synapse did not become healthy."
        error "Check logs: docker compose logs synapse"
        exit 1
    fi
    info "Waiting... (${elapsed}s)"
    sleep 5; elapsed=$((elapsed + 5))
done

success "Synapse is healthy"

# ────────────────────────────────────────────────────────────
# Done
# ────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}${BOLD}Restore completed successfully!${NC}"
echo ""
echo "  Run health check: make status"
echo "  View logs:        make logs-synapse"
echo ""
