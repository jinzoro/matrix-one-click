#!/usr/bin/env bash
# ============================================================
# Matrix Homeserver Stack — Backup Script
# ============================================================
# Usage: bash scripts/backup.sh
#
# Backs up:
#   1. PostgreSQL database (pg_dump, gzipped)
#   2. Synapse config files (homeserver.yaml, log.config)
#   3. Synapse signing key (CRITICAL — do not lose this)
#   4. Synapse media store (from Docker named volume)
#   5. .env file (optional, controlled by BACKUP_ENV)
#
# Output: backups/<TIMESTAMP>/
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
# Configuration
# ────────────────────────────────────────────────────────────
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BACKUP_DIR="${ROOT_DIR}/backups/${TIMESTAMP}"
BACKUP_ENV="${BACKUP_ENV:-false}"
BACKUP_RETENTION_DAYS="${BACKUP_RETENTION_DAYS:-30}"

echo ""
echo -e "${CYAN}Matrix Homeserver Backup — ${TIMESTAMP}${NC}"
echo -e "${CYAN}Output: ${BACKUP_DIR}${NC}"
echo ""

# Create backup directory
mkdir -p "${BACKUP_DIR}"

BACKUP_SUCCESS=true

# ────────────────────────────────────────────────────────────
# Step 1: Backup PostgreSQL
# ────────────────────────────────────────────────────────────
info "Backing up PostgreSQL database (${POSTGRES_DB})..."

PG_DUMP_FILE="${BACKUP_DIR}/postgres_${TIMESTAMP}.sql.gz"

if docker compose exec -T postgres pg_isready -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" &>/dev/null; then
    if docker compose exec -T postgres \
        pg_dump \
        -U "${POSTGRES_USER}" \
        --format=plain \
        --no-acl \
        --no-owner \
        "${POSTGRES_DB}" | gzip > "${PG_DUMP_FILE}"; then
        PG_SIZE=$(du -sh "${PG_DUMP_FILE}" | cut -f1)
        success "PostgreSQL backup: ${PG_DUMP_FILE} (${PG_SIZE})"
    else
        error "PostgreSQL backup failed!"
        BACKUP_SUCCESS=false
    fi
else
    error "PostgreSQL is not responding. Is the container running?"
    BACKUP_SUCCESS=false
fi

# ────────────────────────────────────────────────────────────
# Step 2: Backup Synapse config and signing key
# ────────────────────────────────────────────────────────────
info "Backing up Synapse configuration..."

CONFIG_ARCHIVE="${BACKUP_DIR}/synapse_config_${TIMESTAMP}.tar.gz"

CONFIG_FILES=()
[[ -f "data/synapse/homeserver.yaml" ]] && CONFIG_FILES+=("data/synapse/homeserver.yaml")
[[ -f "data/synapse/log.config" ]]      && CONFIG_FILES+=("data/synapse/log.config")

SIGNING_KEY="data/synapse/${MATRIX_SERVER_NAME}.signing.key"
if [[ -f "${SIGNING_KEY}" ]]; then
    CONFIG_FILES+=("${SIGNING_KEY}")
else
    warn "Signing key not found at ${SIGNING_KEY}"
fi

if [[ ${#CONFIG_FILES[@]} -gt 0 ]]; then
    tar -czf "${CONFIG_ARCHIVE}" "${CONFIG_FILES[@]}"
    CONFIG_SIZE=$(du -sh "${CONFIG_ARCHIVE}" | cut -f1)
    success "Synapse config backup: ${CONFIG_ARCHIVE} (${CONFIG_SIZE})"
else
    warn "No Synapse config files found to back up"
fi

# ────────────────────────────────────────────────────────────
# Step 3: Backup Synapse media store (from named volume)
# ────────────────────────────────────────────────────────────
info "Backing up Synapse media store (from Docker volume)..."

MEDIA_ARCHIVE="${BACKUP_DIR}/synapse_media_${TIMESTAMP}.tar.gz"

if docker volume inspect matrix-synapse-media &>/dev/null; then
    if docker run --rm \
        -v matrix-synapse-media:/data/media_store:ro \
        -v "${BACKUP_DIR}:/backup" \
        alpine \
        tar -czf "/backup/synapse_media_${TIMESTAMP}.tar.gz" -C / data/media_store; then
        MEDIA_SIZE=$(du -sh "${MEDIA_ARCHIVE}" | cut -f1)
        success "Media store backup: ${MEDIA_ARCHIVE} (${MEDIA_SIZE})"
    else
        error "Media store backup failed!"
        BACKUP_SUCCESS=false
    fi
else
    warn "Docker volume matrix-synapse-media not found — media backup skipped"
    warn "(This is normal if Synapse has never been started)"
fi

# ────────────────────────────────────────────────────────────
# Step 4: Backup .env (optional — contains secrets)
# ────────────────────────────────────────────────────────────
if [[ "${BACKUP_ENV}" == "true" ]]; then
    warn "Backing up .env file (BACKUP_ENV=true). This file contains sensitive secrets!"
    warn "Ensure the backup destination is encrypted and secured."
    cp .env "${BACKUP_DIR}/env_${TIMESTAMP}.bak"
    chmod 600 "${BACKUP_DIR}/env_${TIMESTAMP}.bak"
    success ".env backed up (permissions: 600)"
else
    info "Skipping .env backup (set BACKUP_ENV=true to include)"
fi

# ────────────────────────────────────────────────────────────
# Step 5: Create backup manifest
# ────────────────────────────────────────────────────────────
info "Creating backup manifest..."

MANIFEST_FILE="${BACKUP_DIR}/MANIFEST.txt"
{
    echo "Matrix Homeserver Backup Manifest"
    echo "=================================="
    echo "Timestamp:    ${TIMESTAMP}"
    echo "Server:       ${MATRIX_SERVER_NAME}"
    echo "Synapse host: ${SYNAPSE_HOSTNAME}"
    echo "Date:         $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
    echo ""
    echo "Files:"
    for f in "${BACKUP_DIR}"/*; do
        if [[ -f "$f" ]]; then
            fname=$(basename "$f")
            fsize=$(du -sh "$f" | cut -f1)
            fhash=$(sha256sum "$f" | cut -d' ' -f1)
            echo "  ${fname} (${fsize}) sha256:${fhash}"
        fi
    done
    echo ""
    echo "Docker image versions at backup time:"
    docker compose images 2>/dev/null || echo "  (docker compose images not available)"
} > "${MANIFEST_FILE}"

success "Manifest written: ${MANIFEST_FILE}"

# ────────────────────────────────────────────────────────────
# Step 6: Prune old backups
# ────────────────────────────────────────────────────────────
if [[ "${BACKUP_RETENTION_DAYS}" -gt 0 ]]; then
    info "Pruning backups older than ${BACKUP_RETENTION_DAYS} days..."
    PRUNED=0
    while IFS= read -r -d '' old_backup; do
        rm -rf "${old_backup}"
        PRUNED=$((PRUNED + 1))
        info "  Removed: ${old_backup}"
    done < <(find "${ROOT_DIR}/backups" -maxdepth 1 -mindepth 1 -type d -mtime "+${BACKUP_RETENTION_DAYS}" -print0 2>/dev/null)

    if [[ ${PRUNED} -gt 0 ]]; then
        success "Pruned ${PRUNED} old backup(s)"
    else
        info "No old backups to prune"
    fi
fi

# ────────────────────────────────────────────────────────────
# Summary
# ────────────────────────────────────────────────────────────
echo ""
if [[ "${BACKUP_SUCCESS}" == "true" ]]; then
    TOTAL_SIZE=$(du -sh "${BACKUP_DIR}" | cut -f1)
    echo -e "${GREEN}Backup completed successfully!${NC}"
    echo ""
    echo "  Location: ${BACKUP_DIR}"
    echo "  Total size: ${TOTAL_SIZE}"
    echo ""
    echo -e "${YELLOW}Important: Copy this backup to an off-site location!${NC}"
    echo "  rsync -av ${BACKUP_DIR}/ user@remote:/backups/matrix/${TIMESTAMP}/"
else
    echo -e "${RED}Backup completed with errors. Review the output above.${NC}"
    exit 1
fi
echo ""
