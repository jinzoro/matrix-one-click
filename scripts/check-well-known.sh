#!/usr/bin/env bash
# ============================================================
# Matrix Homeserver Stack — Well-Known Check Script
# ============================================================
# Usage: bash scripts/check-well-known.sh
#
# Verifies:
#   1. /.well-known/matrix/client is reachable
#   2. /.well-known/matrix/server is reachable
#   3. Correct Content-Type headers
#   4. CORS Access-Control-Allow-Origin header
#   5. JSON validity
#   6. Values match configured SYNAPSE_HOSTNAME
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

info() {
    echo -e "  ${CYAN}[INFO]${NC} $*"
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "${SCRIPT_DIR}")"
cd "${ROOT_DIR}"

if [[ -f ".env" ]]; then
    set -a
    # shellcheck disable=SC1091
    source .env
    set +a
fi

MATRIX_SERVER_NAME="${MATRIX_SERVER_NAME:-example.com}"
SYNAPSE_HOSTNAME="${SYNAPSE_HOSTNAME:-matrix.example.com}"
SYNAPSE_PUBLIC_BASEURL="${SYNAPSE_PUBLIC_BASEURL:-https://matrix.example.com}"

echo ""
echo -e "${BOLD}${CYAN}Well-Known Endpoint Check — ${MATRIX_SERVER_NAME}${NC}"
echo -e "${CYAN}$(date '+%Y-%m-%d %H:%M:%S')${NC}"

# ════════════════════════════════════════════════════════════
# Check 1: .well-known/matrix/client
# ════════════════════════════════════════════════════════════
echo ""
echo -e "${BOLD}── /.well-known/matrix/client ──${NC}"

CLIENT_URL="https://${MATRIX_SERVER_NAME}/.well-known/matrix/client"
info "URL: ${CLIENT_URL}"

# Fetch with headers
CLIENT_RESPONSE=$(curl -fsSL --max-time 10 \
    -D /tmp/wk_client_headers.txt \
    "${CLIENT_URL}" 2>/dev/null || echo "")

if [[ -z "${CLIENT_RESPONSE}" ]]; then
    fail "No response from ${CLIENT_URL}"
else
    info "Response body: ${CLIENT_RESPONSE}"

    # Check Content-Type header
    if grep -qi "content-type:.*application/json" /tmp/wk_client_headers.txt 2>/dev/null; then
        pass "Content-Type: application/json"
    else
        CT=$(grep -i "content-type:" /tmp/wk_client_headers.txt 2>/dev/null | head -1 | tr -d '\r' || echo "not found")
        warn "Content-Type is '${CT}' — expected 'application/json'"
    fi

    # Check CORS header
    if grep -qi "access-control-allow-origin" /tmp/wk_client_headers.txt 2>/dev/null; then
        CORS=$(grep -i "access-control-allow-origin:" /tmp/wk_client_headers.txt 2>/dev/null | head -1 | tr -d '\r' || echo "")
        pass "CORS header present: ${CORS}"
    else
        fail "Missing Access-Control-Allow-Origin header (required for browser clients)"
    fi

    # Check JSON validity
    if echo "${CLIENT_RESPONSE}" | python3 -m json.tool &>/dev/null 2>&1; then
        pass "Response is valid JSON"
    elif command -v jq &>/dev/null && echo "${CLIENT_RESPONSE}" | jq . &>/dev/null; then
        pass "Response is valid JSON"
    else
        fail "Response is not valid JSON"
    fi

    # Check m.homeserver key
    if echo "${CLIENT_RESPONSE}" | grep -q '"m.homeserver"'; then
        pass "m.homeserver key present"

        # Check base_url value
        if echo "${CLIENT_RESPONSE}" | grep -q "${SYNAPSE_PUBLIC_BASEURL}"; then
            pass "base_url matches SYNAPSE_PUBLIC_BASEURL (${SYNAPSE_PUBLIC_BASEURL})"
        else
            ACTUAL_URL=$(echo "${CLIENT_RESPONSE}" | grep -oP '"base_url"\s*:\s*"\K[^"]+' 2>/dev/null | head -1 || echo "unknown")
            fail "base_url '${ACTUAL_URL}' does not match SYNAPSE_PUBLIC_BASEURL '${SYNAPSE_PUBLIC_BASEURL}'"
        fi
    else
        fail "m.homeserver key missing from client response"
    fi

    # Check m.identity_server (optional but recommended)
    if echo "${CLIENT_RESPONSE}" | grep -q '"m.identity_server"'; then
        pass "m.identity_server key present (optional)"
    else
        warn "m.identity_server key missing (optional, but recommended for identity lookups)"
    fi
fi

# Clean up temp file
rm -f /tmp/wk_client_headers.txt

# ════════════════════════════════════════════════════════════
# Check 2: .well-known/matrix/server
# ════════════════════════════════════════════════════════════
echo ""
echo -e "${BOLD}── /.well-known/matrix/server ──${NC}"

SERVER_URL="https://${MATRIX_SERVER_NAME}/.well-known/matrix/server"
info "URL: ${SERVER_URL}"

SERVER_RESPONSE=$(curl -fsSL --max-time 10 \
    -D /tmp/wk_server_headers.txt \
    "${SERVER_URL}" 2>/dev/null || echo "")

if [[ -z "${SERVER_RESPONSE}" ]]; then
    fail "No response from ${SERVER_URL}"
else
    info "Response body: ${SERVER_RESPONSE}"

    # Check Content-Type
    if grep -qi "content-type:.*application/json" /tmp/wk_server_headers.txt 2>/dev/null; then
        pass "Content-Type: application/json"
    else
        CT=$(grep -i "content-type:" /tmp/wk_server_headers.txt 2>/dev/null | head -1 | tr -d '\r' || echo "not found")
        warn "Content-Type is '${CT}' — expected 'application/json'"
    fi

    # Check JSON validity
    if echo "${SERVER_RESPONSE}" | python3 -m json.tool &>/dev/null 2>&1; then
        pass "Response is valid JSON"
    elif command -v jq &>/dev/null && echo "${SERVER_RESPONSE}" | jq . &>/dev/null; then
        pass "Response is valid JSON"
    else
        fail "Response is not valid JSON"
    fi

    # Check m.server key
    if echo "${SERVER_RESPONSE}" | grep -q '"m.server"'; then
        pass "m.server key present"

        # Check value
        M_SERVER=$(echo "${SERVER_RESPONSE}" | grep -oP '"m\.server"\s*:\s*"\K[^"]+' 2>/dev/null | head -1 || echo "unknown")
        info "m.server value: ${M_SERVER}"

        if echo "${M_SERVER}" | grep -q "${SYNAPSE_HOSTNAME}"; then
            pass "m.server points to SYNAPSE_HOSTNAME (${SYNAPSE_HOSTNAME})"
        else
            fail "m.server '${M_SERVER}' does not contain SYNAPSE_HOSTNAME '${SYNAPSE_HOSTNAME}'"
        fi

        # Should include port 443
        if echo "${M_SERVER}" | grep -q ":443"; then
            pass "m.server includes :443 port"
        else
            warn "m.server does not include ':443' — remote servers may default to 8448"
        fi
    else
        fail "m.server key missing from server response"
    fi
fi

rm -f /tmp/wk_server_headers.txt

# ════════════════════════════════════════════════════════════
# Summary
# ════════════════════════════════════════════════════════════
echo ""
echo -e "${BOLD}──────────────────────────────────────${NC}"
echo -e "${BOLD}Well-Known Check Summary${NC}"
echo -e "  ${GREEN}PASS: ${PASS_COUNT}${NC}"
echo -e "  ${YELLOW}WARN: ${WARN_COUNT}${NC}"
echo -e "  ${RED}FAIL: ${FAIL_COUNT}${NC}"
echo -e "${BOLD}──────────────────────────────────────${NC}"
echo ""

if [[ ${FAIL_COUNT} -gt 0 ]]; then
    echo -e "${RED}Well-known check FAILED.${NC}"
    echo "  See docs/TROUBLESHOOTING.md for help."
    exit 1
else
    echo -e "${GREEN}Well-known endpoints are correctly configured!${NC}"
    exit 0
fi
