# DNS Configuration Guide

This document explains all the DNS records required for the Matrix homeserver stack and how the Matrix server name delegation system works.

## Understanding server_name vs Synapse hostname

Matrix has two distinct hostname concepts:

### `server_name` (MATRIX_SERVER_NAME)
The **Matrix identity domain**. This is the domain that appears in all Matrix IDs:
- User IDs: `@alice:example.com`
- Room aliases: `#general:example.com`
- Room IDs: `!abc123:example.com`

Once set, this **cannot be changed**. It is baked into the signing key and all room memberships.

### `SYNAPSE_HOSTNAME`
The hostname where Synapse actually runs (e.g. `matrix.example.com`). Remote servers use the well-known delegation file or SRV record to discover this.

### Why they can differ

You may want your Matrix IDs to be `@alice:example.com` (clean, memorable) but host Synapse at `matrix.example.com` (doesn't interfere with your main website). The well-known delegation file bridges this gap.

---

## Required DNS Records

### Minimum required records

| Hostname | Record Type | Value | Purpose |
|---|---|---|---|
| `matrix.example.com` | A | `<server-ip>` | Synapse homeserver (required) |
| `chat.example.com` | A | `<server-ip>` | Element Web client (required) |
| `example.com` | A | `<server-ip>` | Well-known delegation (if using delegation) |

If `MATRIX_SERVER_NAME == SYNAPSE_HOSTNAME` (e.g., both are `matrix.example.com`), you don't need the base domain record for Matrix, but you still need `matrix.example.com` to have an A record.

### With IPv6 (recommended)

| Hostname | Record Type | Value |
|---|---|---|
| `matrix.example.com` | AAAA | `<your-server-ipv6>` |
| `chat.example.com` | AAAA | `<your-server-ipv6>` |
| `example.com` | AAAA | `<your-server-ipv6>` |

---

## Well-Known Delegation

When `MATRIX_SERVER_NAME` is different from `SYNAPSE_HOSTNAME`, other Matrix servers need to discover where your Synapse is running.

This is done via the well-known delegation file at:
```
https://example.com/.well-known/matrix/server
```

This file contains:
```json
{
  "m.server": "matrix.example.com:443"
}
```

The `well-known` service in this stack serves this file automatically after bootstrap processes the templates.

### How remote servers find your homeserver

1. Remote server wants to contact `@alice:example.com`
2. Remote server checks `https://example.com/.well-known/matrix/server`
3. File says: connect to `matrix.example.com:443`
4. Remote server connects to Synapse via port 443 (using TLS)
5. If step 2 fails, remote server falls back to trying port 8448 on `example.com`

---

## SRV Records (Alternative to Well-Known)

Instead of well-known, you can use a DNS SRV record to delegate federation:

```
_matrix._tcp.example.com.  3600  IN  SRV  10 5 443 matrix.example.com.
```

However, well-known delegation is preferred because:
- It works over standard HTTPS (port 443) — firewalls rarely block this
- It's easier to update (no DNS TTL waiting)
- It's the Matrix specification's recommended approach

This stack uses well-known delegation. If you also want SRV records, you can add them without breaking anything.

---

## Optional: MX Record for Email

If you enable email notifications (`MATRIX_EMAIL_ENABLED=true`), you need the standard `example.com` to have an MX record pointing to your mail server.

```
example.com.  3600  IN  MX  10 mail.example.com.
```

This is only needed if Synapse needs to send emails **from** `@example.com` addresses. If you use an external SMTP relay (SendGrid, Mailgun, etc.), the `example.com` MX record is not required for Synapse to work.

---

## TTL Recommendations

| Record | Recommended TTL | Notes |
|---|---|---|
| A records (initial setup) | 300 (5 min) | Short during testing — change easily |
| A records (production) | 3600 (1 hour) | Lower cache pressure than 24h |
| MX records | 3600 | |
| SRV records | 3600 | |

---

## DNS Propagation

After creating records, propagation time depends on your DNS provider:
- Most providers: 5–15 minutes
- Some providers: up to 1 hour
- Maximum: 48 hours (very rare)

### Checking propagation

```bash
# Check from your server
dig +short matrix.example.com
dig +short chat.example.com
dig +short example.com

# Check from a different location (DNS propagation checker)
# https://dnschecker.org/

# Check with explicit DNS server
dig @8.8.8.8 +short matrix.example.com
dig @1.1.1.1 +short matrix.example.com
```

**Do not start the bootstrap until all DNS records resolve to your server IP.**

Traefik's ACME (Let's Encrypt) challenge requires the hostname to resolve before it can issue a certificate.

---

## Verifying Well-Known After Setup

After the stack is running, verify your well-known endpoints:

```bash
# Should return JSON with m.homeserver.base_url
curl -fsSL https://example.com/.well-known/matrix/client | jq .

# Should return JSON with m.server
curl -fsSL https://example.com/.well-known/matrix/server | jq .

# Use the built-in check script
bash scripts/check-well-known.sh
```

---

## Split-Horizon DNS (Internal Servers)

If your server is behind NAT or a private network, you may need split-horizon DNS:
- External DNS: `matrix.example.com` → public IP
- Internal DNS: `matrix.example.com` → internal/private IP

This is usually only needed in corporate environments. On typical VPS deployments, this is not required.

---

## Troubleshooting DNS Issues

**Let's Encrypt certificate fails to issue:**
- DNS A record must resolve before Traefik can obtain the certificate
- Check with: `dig +short matrix.example.com`
- Should return your server's public IP

**Federation not working:**
- Well-known delegation file might be incorrect
- Use: `bash scripts/check-well-known.sh`
- Check: https://federationtester.matrix.org/

**Element can't connect to homeserver:**
- Check `SYNAPSE_PUBLIC_BASEURL` in `.env` matches the configured DNS
- Verify `config/element/config.json` has the correct `base_url`
