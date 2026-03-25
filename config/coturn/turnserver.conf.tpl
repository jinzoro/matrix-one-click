# ============================================================
# Coturn TURN/STUN Server Configuration — TEMPLATE
# ============================================================
# This is a template processed by bootstrap.sh.
# Output: data/coturn/turnserver.conf
#
# Variables of the form %%VARIABLE%% are replaced by sed
# substitution in bootstrap.sh using values from .env.
#
# ⚠  SECURITY: The denied-peer-ip entries below are CRITICAL.
# They prevent attackers from using your TURN server as a
# proxy to reach internal services (SSRF via TURN).
# All RFC1918 private ranges, loopback, link-local, and
# reserved address ranges are denied.
# ============================================================

# ──────────────────────────────────────────────────────────
# Network — Listening addresses and ports
# ──────────────────────────────────────────────────────────
listening-port=%%COTURN_PORT%%
tls-listening-port=%%COTURN_TLS_PORT%%

# Listen on all interfaces (host network mode)
listening-ip=0.0.0.0

# External IP address for relay allocation.
# This must be your server's public IPv4 address.
relay-ip=%%COTURN_RELAY_IP%%
external-ip=%%COTURN_RELAY_IP%%

# ──────────────────────────────────────────────────────────
# UDP port range for media relay
# Must match COTURN_MIN_PORT and COTURN_MAX_PORT in .env
# AND the ports exposed in compose.yaml
# ──────────────────────────────────────────────────────────
min-port=%%COTURN_MIN_PORT%%
max-port=%%COTURN_MAX_PORT%%

# ──────────────────────────────────────────────────────────
# Authentication
# ──────────────────────────────────────────────────────────
# Add HMAC fingerprint to TURN messages
fingerprint

# Use TURN REST API shared secret (recommended for Synapse)
use-auth-secret

# Shared secret — MUST match COTURN_STATIC_AUTH_SECRET in .env
# and turn_shared_secret in homeserver.yaml
static-auth-secret=%%COTURN_STATIC_AUTH_SECRET%%

# Realm for TURN authentication
realm=%%COTURN_REALM%%

# ──────────────────────────────────────────────────────────
# Resource limits
# ──────────────────────────────────────────────────────────
# Maximum simultaneous allocations
total-quota=1200

# Bandwidth limit per session (0 = unlimited)
bps-capacity=0

# Stale nonce expiry in seconds
stale-nonce=600

# ──────────────────────────────────────────────────────────
# Security — Deny private and reserved IP ranges
# ──────────────────────────────────────────────────────────
# IMPORTANT: These rules PREVENT your TURN server from being
# used as a proxy to attack internal/private network resources.
# This mitigates SSRF (Server-Side Request Forgery) attacks
# that exploit TURN servers to reach internal hosts.
# Remove any of these at your own risk.

# 0.0.0.0/8 — "This" network (RFC 1122)
denied-peer-ip=0.0.0.0-0.255.255.255

# 10.0.0.0/8 — Private network (RFC 1918)
denied-peer-ip=10.0.0.0-10.255.255.255

# 100.64.0.0/10 — Shared address space (RFC 6598, carrier-grade NAT)
denied-peer-ip=100.64.0.0-100.127.255.255

# 127.0.0.0/8 — Loopback (RFC 5735)
denied-peer-ip=127.0.0.0-127.255.255.255

# 169.254.0.0/16 — Link-local / APIPA (RFC 3927)
denied-peer-ip=169.254.0.0-169.254.255.255

# 172.16.0.0/12 — Private network (RFC 1918)
denied-peer-ip=172.16.0.0-172.31.255.255

# 192.0.0.0/24 — IETF Protocol Assignments (RFC 6890)
denied-peer-ip=192.0.0.0-192.0.0.255

# 192.168.0.0/16 — Private network (RFC 1918)
denied-peer-ip=192.168.0.0-192.168.255.255

# 198.18.0.0/15 — Benchmarking (RFC 2544)
denied-peer-ip=198.18.0.0-198.19.255.255

# 198.51.100.0/24 — Documentation (TEST-NET-2, RFC 5737)
denied-peer-ip=198.51.100.0-198.51.100.255

# 203.0.113.0/24 — Documentation (TEST-NET-3, RFC 5737)
denied-peer-ip=203.0.113.0-203.0.113.255

# 240.0.0.0/4 — Reserved (RFC 1112)
denied-peer-ip=240.0.0.0-255.255.255.255

# ──────────────────────────────────────────────────────────
# Additional security options
# ──────────────────────────────────────────────────────────
# Disallow relaying to multicast addresses
no-multicast-peers

# ──────────────────────────────────────────────────────────
# Logging
# ──────────────────────────────────────────────────────────
# Log to syslog
syslog

# Verbose logging (set to 'verbose' for debugging, remove for production)
verbose

# Log file path (inside container)
log-file=/var/log/coturn/turnserver.log

# PID file
pidfile=/var/run/coturn/turnserver.pid
