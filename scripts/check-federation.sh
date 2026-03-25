#!/usr/bin/env bash
# ============================================================
# Matrix Homeserver Stack — Federation Check Script
# ============================================================
# Usage: bash scripts/check-federation.sh
#
# Checks:
#   1. .well-known/matrix/server on MATRIX_SERVER_NAME
#   2. Matrix federation version endpoint
#   3. Federation tester (matrix.org)
#   4. Port 8448 reachability
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

pass() {
    echo -e "  ${GREEN}[PASS]${NC} $*"
    PASS_COUNT=$((PASS_COUNT + 1))
}

fail() {
    echo -e "  ${RED}[FAIL]${NC} $*"
    FAIL_COUNT=$((FAIL_COUNT + 1))
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
echo -e "${BOLD}${CYAN}Matrix Federation Check — ${MATRIX_SERVER_NAME}${NC}"
echo -e "${CYAN}$(date '+%Y-%m-%d %H:%M:%S')${NC}"

# ════════════════════════════════════════════════════════════
# Check 1: Well-known matrix/server
# ════════════════════════════════════════════════════════════
echo ""
echo -e "${BOLD}── Well-known (server delegation) ──${NC}"

WK_SERVER_URL="https://${MATRIX_SERVER_NAME}/.well-known/matrix/server"
info "Fetching: ${WK_SERVER_URL}"

WK_SERVER_RESPONSE=$(curl -fsSL --max-time 10 \
    -H "Accept: application/json" \
    "${WK_SERVER_URL}" 2>/dev/null || echo "")

if [[ -z "${WK_SERVER_RESPONSE}" ]]; then
    fail ".well-known/matrix/server: no response from ${WK_SERVER_URL}"
else
    echo -e "  ${CYAN}Response:${NC} ${WK_SERVER_RESPONSE}"
    if echo "${WK_SERVER_RESPONSE}" | grep -q '"m.server"'; then
        DELEGATED_SERVER=$(echo "${WK_SERVER_RESPONSE}" | grep -oP '"m\.server"\s*:\s*"\K[^"]+' 2>/dev/null || echo "unknown")
        pass ".well-known/matrix/server: present (m.server: ${DELEGATED_SERVER})"

        # Verify it points to our Synapse hostname
        if echo "${DELEGATED_SERVER}" | grep -q "${SYNAPSE_HOSTNAME}"; then
            pass "Delegation target matches SYNAPSE_HOSTNAME (${SYNAPSE_HOSTNAME})"
        else
            fail "Delegation target '${DELEGATED_SERVER}' does not match SYNAPSE_HOSTNAME '${SYNAPSE_HOSTNAME}'"
        fi
    else
        fail ".well-known/matrix/server: missing 'm.server' key in response"
    fi
fi

# ════════════════════════════════════════════════════════════
# Check 2: Federation version endpoint
# ════════════════════════════════════════════════════════════
echo ""
echo -e "${BOLD}── Federation Version Endpoint ──${NC}"

FED_VERSION_URL="${SYNAPSE_PUBLIC_BASEURL}/_matrix/federation/v1/version"
info "Fetching: ${FED_VERSION_URL}"

FED_VERSION_RESPONSE=$(curl -fsSL --max-time 15 "${FED_VERSION_URL}" 2>/dev/null || echo "")

if [[ -z "${FED_VERSION_RESPONSE}" ]]; then
    fail "Federation version endpoint: no response from ${FED_VERSION_URL}"
else
    SYNAPSE_VERSION=$(echo "${FED_VERSION_RESPONSE}" | grep -oP '"version"\s*:\s*"\K[^"]+' 2>/dev/null | head -1 || echo "unknown")
    pass "Federation version endpoint: responding (Synapse version: ${SYNAPSE_VERSION})"
fi

# Check on port 8448 directly
FED_PORT_URL="https://${SYNAPSE_HOSTNAME}:8448/_matrix/federation/v1/version"
info "Fetching via port 8448: ${FED_PORT_URL}"

FED_PORT_RESPONSE=$(curl -fsSL --max-time 15 "${FED_PORT_URL}" 2>/dev/null || echo "")
if [[ -n "${FED_PORT_RESPONSE}" ]] && echo "${FED_PORT_RESPONSE}" | grep -q "version"; then
    pass "Port 8448: federation endpoint responding directly"
else
    fail "Port 8448: federation endpoint not reachable at ${FED_PORT_URL}"
    info "  Ensure port 8448 is open in your firewall/security group"
fi

# ════════════════════════════════════════════════════════════
# Check 3: Matrix federation tester
# ════════════════════════════════════════════════════════════
echo ""
echo -e "${BOLD}── Matrix Federation Tester (matrix.org) ──${NC}"

TESTER_URL="https://federationtester.matrix.org/api/report?server_name=${MATRIX_SERVER_NAME}"
info "Querying: ${TESTER_URL}"
info "(This may take up to 30 seconds)"

TESTER_RESPONSE=$(curl -fsSL --max-time 30 "${TESTER_URL}" 2>/dev/null || echo "")

if [[ -z "${TESTER_RESPONSE}" ]]; then
    fail "Federation tester: could not reach federationtester.matrix.org"
    info "  You can check manually at: https://federationtester.matrix.org/#${MATRIX_SERVER_NAME}"
else
    # Parse basic success/failure
    if echo "${TESTER_RESPONSE}" | grep -q '"FederationOK":true'; then
        pass "Federation tester: FederationOK = true (matrix.org can federate with you!)"
    elif echo "${TESTER_RESPONSE}" | grep -q '"FederationOK":false'; then
        fail "Federation tester: FederationOK = false"
        info "  Check details at: https://federationtester.matrix.org/#${MATRIX_SERVER_NAME}"
    else
        info "Federation tester: Could not parse result. Check manually:"
        info "  https://federationtester.matrix.org/#${MATRIX_SERVER_NAME}"
    fi

    # Check for connectivity result
    if echo "${TESTER_RESPONSE}" | grep -q '"WellKnownResult"'; then
        WK_RESULT=$(echo "${TESTER_RESPONSE}" | grep -oP '"WellKnownResult":\{"StatusCode":\K[0-9]+' 2>/dev/null || echo "unknown")
        info "  Well-known status code: ${WK_RESULT}"
    fi
fi

# ════════════════════════════════════════════════════════════
# Summary
# ════════════════════════════════════════════════════════════
echo ""
echo -e "${BOLD}──────────────────────────────────────${NC}"
echo -e "${BOLD}Federation Check Summary${NC}"
echo -e "  ${GREEN}PASS: ${PASS_COUNT}${NC}"
echo -e "  ${RED}FAIL: ${FAIL_COUNT}${NC}"
echo -e "${BOLD}──────────────────────────────────────${NC}"
echo ""

if [[ ${FAIL_COUNT} -gt 0 ]]; then
    echo -e "${RED}Federation check FAILED.${NC}"
    echo ""
    echo "  Troubleshooting resources:"
    echo "  - https://federationtester.matrix.org/#${MATRIX_SERVER_NAME}"
    echo "  - docs/FEDERATION.md"
    echo "  - docs/TROUBLESHOOTING.md"
    echo ""
    exit 1
else
    echo -e "${GREEN}Federation is working!${NC}"
    exit 0
fi
