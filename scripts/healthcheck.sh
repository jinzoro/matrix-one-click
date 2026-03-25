#!/usr/bin/env bash
# ============================================================
# Matrix Homeserver Stack — Health Check Script
# ============================================================
# Usage: bash scripts/healthcheck.sh
#
# Checks:
#   1. Container status for all services
#   2. Synapse health endpoint
#   3. PostgreSQL connectivity
#   4. Redis connectivity
#   5. Traefik ping endpoint
#   6. External HTTPS reachability (Synapse + Element)
#   7. Well-known endpoints
# ============================================================

set -euo pipefail

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
ROOT_DIR="$(dirname "${SCRIPT_DIR}")"
cd "${ROOT_DIR}"

# ────────────────────────────────────────────────────────────
# Load .env
# ────────────────────────────────────────────────────────────
if [[ -f ".env" ]]; then
    set -a
    # shellcheck disable=SC1091
    source .env
    set +a
else
    echo -e "${YELLOW}Warning: .env not found — some checks may be incomplete${NC}"
fi

echo ""
echo -e "${BOLD}${CYAN}Matrix Homeserver Health Check${NC}"
echo -e "${CYAN}$(date '+%Y-%m-%d %H:%M:%S')${NC}"

# ════════════════════════════════════════════════════════════
# Check 1: Container status
# ════════════════════════════════════════════════════════════
section "Container Status"

for service in traefik postgres redis synapse element-web coturn well-known; do
    if docker compose ps "${service}" 2>/dev/null | grep -qi "up\|running\|healthy"; then
        CONTAINER_STATUS=$(docker compose ps "${service}" 2>/dev/null | tail -1 | awk '{print $NF}')
        pass "${service}: running (${CONTAINER_STATUS})"
    else
        fail "${service}: not running"
    fi
done

# ════════════════════════════════════════════════════════════
# Check 2: Synapse health endpoint
# ════════════════════════════════════════════════════════════
section "Synapse Internal Health"

if docker compose exec -T synapse curl -fsSL --max-time 5 http://localhost:8008/health &>/dev/null; then
    pass "Synapse /health endpoint: OK"
else
    fail "Synapse /health endpoint: not responding"
fi

# Check Synapse client versions endpoint
if docker compose exec -T synapse curl -fsSL --max-time 5 \
    "http://localhost:8008/_matrix/client/versions" &>/dev/null; then
    pass "Synapse /_matrix/client/versions: OK"
else
    fail "Synapse /_matrix/client/versions: not responding"
fi

# ════════════════════════════════════════════════════════════
# Check 3: PostgreSQL
# ════════════════════════════════════════════════════════════
section "PostgreSQL"

if docker compose exec -T postgres \
    pg_isready -U "${POSTGRES_USER:-synapse}" -d "${POSTGRES_DB:-synapse}" &>/dev/null; then
    pass "PostgreSQL: accepting connections"
else
    fail "PostgreSQL: not ready"
fi

# Check that synapse tables exist
TABLE_COUNT=$(docker compose exec -T postgres \
    psql -U "${POSTGRES_USER:-synapse}" "${POSTGRES_DB:-synapse}" \
    -t -c "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='public';" \
    2>/dev/null | tr -d '[:space:]' || echo "0")

if [[ "${TABLE_COUNT:-0}" -gt 10 ]]; then
    pass "PostgreSQL: ${TABLE_COUNT} tables in synapse schema (Synapse schema applied)"
elif [[ "${TABLE_COUNT:-0}" -gt 0 ]]; then
    warn "PostgreSQL: only ${TABLE_COUNT} tables — Synapse may not have migrated yet"
else
    warn "PostgreSQL: no tables found — Synapse has not run migrations yet"
fi

# ════════════════════════════════════════════════════════════
# Check 4: Redis
# ════════════════════════════════════════════════════════════
section "Redis"

if docker compose exec -T redis \
    redis-cli -a "${REDIS_PASSWORD:-}" ping 2>/dev/null | grep -q "PONG"; then
    pass "Redis: responding to PING"
else
    fail "Redis: not responding"
fi

# ════════════════════════════════════════════════════════════
# Check 5: Traefik
# ════════════════════════════════════════════════════════════
section "Traefik"

if docker compose exec -T traefik \
    wget --no-verbose --tries=1 --spider http://localhost:80/ping &>/dev/null; then
    pass "Traefik: ping endpoint responding"
else
    fail "Traefik: ping not responding"
fi

# ════════════════════════════════════════════════════════════
# Check 6: External HTTPS reachability
# ════════════════════════════════════════════════════════════
section "External HTTPS (requires DNS + TLS)"

SYNAPSE_PUBLIC_BASEURL="${SYNAPSE_PUBLIC_BASEURL:-https://matrix.example.com}"
ELEMENT_HOSTNAME="${ELEMENT_HOSTNAME:-chat.example.com}"
MATRIX_SERVER_NAME="${MATRIX_SERVER_NAME:-example.com}"

# Check Synapse externally
if curl -fsSL --max-time 10 \
    "${SYNAPSE_PUBLIC_BASEURL}/_matrix/client/versions" &>/dev/null; then
    pass "Synapse external HTTPS: ${SYNAPSE_PUBLIC_BASEURL}/_matrix/client/versions"
else
    fail "Synapse external HTTPS: ${SYNAPSE_PUBLIC_BASEURL}/_matrix/client/versions not reachable"
fi

# Check Element Web externally
if curl -fsSL --max-time 10 \
    "https://${ELEMENT_HOSTNAME}/" &>/dev/null; then
    pass "Element Web external HTTPS: https://${ELEMENT_HOSTNAME}/"
else
    fail "Element Web external HTTPS: https://${ELEMENT_HOSTNAME}/ not reachable"
fi

# ════════════════════════════════════════════════════════════
# Check 7: Well-known endpoints
# ════════════════════════════════════════════════════════════
section "Well-known Endpoints"

# Check .well-known/matrix/client
WELL_KNOWN_CLIENT=$(curl -fsSL --max-time 10 \
    "https://${MATRIX_SERVER_NAME}/.well-known/matrix/client" 2>/dev/null || echo "")

if [[ -n "${WELL_KNOWN_CLIENT}" ]]; then
    if echo "${WELL_KNOWN_CLIENT}" | grep -q "m.homeserver"; then
        pass ".well-known/matrix/client: valid JSON with m.homeserver"
    else
        warn ".well-known/matrix/client: returned data but missing m.homeserver key"
    fi
else
    fail ".well-known/matrix/client: not reachable at https://${MATRIX_SERVER_NAME}/.well-known/matrix/client"
fi

# Check .well-known/matrix/server
WELL_KNOWN_SERVER=$(curl -fsSL --max-time 10 \
    "https://${MATRIX_SERVER_NAME}/.well-known/matrix/server" 2>/dev/null || echo "")

if [[ -n "${WELL_KNOWN_SERVER}" ]]; then
    if echo "${WELL_KNOWN_SERVER}" | grep -q "m.server"; then
        pass ".well-known/matrix/server: valid JSON with m.server"
    else
        warn ".well-known/matrix/server: returned data but missing m.server key"
    fi
else
    fail ".well-known/matrix/server: not reachable at https://${MATRIX_SERVER_NAME}/.well-known/matrix/server"
fi

# ════════════════════════════════════════════════════════════
# Summary
# ════════════════════════════════════════════════════════════
echo ""
echo -e "${BOLD}──────────────────────────────────────${NC}"
echo -e "${BOLD}Health Check Summary${NC}"
echo -e "  ${GREEN}PASS: ${PASS_COUNT}${NC}"
echo -e "  ${YELLOW}WARN: ${WARN_COUNT}${NC}"
echo -e "  ${RED}FAIL: ${FAIL_COUNT}${NC}"
echo -e "${BOLD}──────────────────────────────────────${NC}"
echo ""

if [[ ${FAIL_COUNT} -gt 0 ]]; then
    echo -e "${RED}${BOLD}Health check FAILED. See issues above.${NC}"
    exit 1
else
    echo -e "${GREEN}${BOLD}Health check PASSED.${NC}"
    if [[ ${WARN_COUNT} -gt 0 ]]; then
        echo -e "${YELLOW}Review warnings above.${NC}"
    fi
    exit 0
fi
