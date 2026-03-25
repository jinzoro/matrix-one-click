# Federation Guide

## What Is Matrix Federation?

Matrix federation allows different Matrix homeservers to communicate with each other. When federation is enabled, users on your homeserver can:

- Join rooms hosted on other homeservers (e.g., rooms on `matrix.org`)
- Communicate with users on other homeservers (`@alice:other.example.com`)
- Participate in federated public room directories

Without federation, your homeserver is completely isolated — users can only communicate with other users on the same homeserver.

---

## How This Stack Enables Federation

This stack enables federation in two ways simultaneously:

### 1. Well-Known Delegation (port 443)

The `well-known` service serves `/.well-known/matrix/server` at:
```
https://example.com/.well-known/matrix/server
```

This file contains:
```json
{
  "m.server": "matrix.example.com:443"
}
```

When a remote server wants to contact your homeserver, it:
1. Fetches this file from your identity domain (`example.com`)
2. Learns that Synapse is at `matrix.example.com:443`
3. Connects to Synapse via HTTPS on port 443 (handled by Traefik)

### 2. Direct Federation on Port 8448

Traefik also listens on port 8448 with a dedicated entrypoint (`matrix-federation`) and routes federation traffic directly to Synapse. This serves as a fallback if well-known delegation fails, and is required by some older Matrix implementations.

---

## Port Requirements for Federation

| Port | Protocol | Direction | Purpose |
|---|---|---|---|
| 443 | TCP | Inbound | Federation via well-known delegation |
| 8448 | TCP | Inbound | Direct Matrix federation (fallback/compatibility) |
| 443 | TCP | Outbound | Your server contacting other servers |

Both ports 443 and 8448 **must be open** in your firewall/security group for full federation compatibility.

---

## When Well-Known Is Needed

| Scenario | Well-Known Needed? |
|---|---|
| `MATRIX_SERVER_NAME=example.com`, `SYNAPSE_HOSTNAME=matrix.example.com` | **Yes** — delegation needed |
| `MATRIX_SERVER_NAME=matrix.example.com`, `SYNAPSE_HOSTNAME=matrix.example.com` | No — both are the same |
| `MATRIX_SERVER_NAME=matrix.example.com`, direct access on :8448 | No — SRV or direct works |

This stack always deploys the `well-known` service, which only activates (via Traefik routing) when traffic hits the `MATRIX_SERVER_NAME` hostname.

---

## SRV Record Alternative

Instead of well-known, you can use a DNS SRV record:

```
_matrix._tcp.example.com.  3600  IN  SRV  10 5 443 matrix.example.com.
```

However, well-known is strongly preferred because:
- Browsers and reverse proxies already support HTTPS well
- SRV records can be blocked by restrictive firewalls
- Well-known is the Matrix spec's recommended method

You can have both — they complement each other.

---

## Testing Federation

### Method 1: Built-in script

```bash
bash scripts/check-federation.sh
```

### Method 2: Matrix.org Federation Tester

Visit: https://federationtester.matrix.org/

Enter your server name (e.g., `example.com`) and the tester will:
- Check your well-known records
- Attempt to connect to your homeserver
- Report any issues found

### Method 3: Manual tests

```bash
# Check well-known/server
curl -fsSL https://example.com/.well-known/matrix/server | jq .

# Check federation version endpoint via port 443
curl -fsSL https://matrix.example.com/_matrix/federation/v1/version | jq .

# Check federation version endpoint via port 8448
curl -fsSL https://matrix.example.com:8448/_matrix/federation/v1/version | jq .

# Check signing keys endpoint
curl -fsSL https://matrix.example.com/_matrix/key/v2/server | jq .

# Test connectivity to matrix.org
curl -fsSL https://matrix.org/_matrix/federation/v1/version | jq .
```

### Method 4: Join a test room

After setting up, join `#matrix:matrix.org` from your homeserver. If you can see messages and participate, federation is working.

---

## Federating with matrix.org

By default, `matrix.org` is configured as a trusted key server in `homeserver.yaml`:

```yaml
trusted_key_servers:
  - server_name: "matrix.org"
```

This means your server will verify signing keys of remote servers using matrix.org's key server. This is the standard configuration.

To federate with matrix.org rooms, simply join any public room hosted there from your Element client.

---

## Blocking/Allowing Federation with Specific Servers

### Blocking specific servers (federation blacklist)

Add to `config/synapse/homeserver.yaml.tpl`:
```yaml
federation_domain_whitelist: null  # null means allow all

# Block specific servers
federation_domain_blacklist:
  - "spammy-server.com"
  - "abusive-instance.net"
```

### Allowing only specific servers (federation whitelist)

```yaml
# Only allow federation with these servers
federation_domain_whitelist:
  - "matrix.org"
  - "trusted-partner.com"
```

If `federation_domain_whitelist` is set to a list, ONLY those servers can federate with you.

After modifying, run:
```bash
bash scripts/init-synapse.sh
docker compose restart synapse
```

---

## Federation Debugging

### Check what your server knows about a remote server

```bash
ACCESS_TOKEN="your-admin-token"
# List currently active federation connections
curl -H "Authorization: Bearer ${ACCESS_TOKEN}" \
  "https://matrix.example.com/_synapse/admin/v1/federation/destinations" | jq .
```

### View federation transaction statistics

```bash
curl -H "Authorization: Bearer ${ACCESS_TOKEN}" \
  "https://matrix.example.com/_synapse/admin/v1/federation/destinations/matrix.org" | jq .
```

### Enable federation logging (for debugging)

In `config/synapse/log.config.tpl`, temporarily change the federation logger level:
```yaml
loggers:
  synapse.federation:
    level: DEBUG
```

Then restart Synapse and watch logs:
```bash
docker compose logs -f synapse | grep federation
```

Remember to set it back to WARNING after debugging.

### Common federation log messages

| Message | Meaning |
|---|---|
| `Starting replication request` | Synapse sending to another server |
| `Rejecting inbound connection` | Incoming federation blocked |
| `Failed to get server keys` | Can't verify remote server signature |
| `Remote server is unreachable` | Network/firewall issue |
| `clock skew` | Server clocks not synchronized |

---

## Performance Implications of Federation

Federation can significantly increase Synapse's resource usage:

- **Large federated rooms**: Rooms with thousands of members from dozens of servers generate enormous traffic
- **Key verification**: Synapse must verify cryptographic signatures from every remote server
- **Media download**: Federated media is downloaded and cached locally

If performance is a concern:
1. Disable federation for internal/private deployments (`SYNAPSE_FEDERATION_ENABLED=false`)
2. Avoid joining very large public rooms (e.g., Matrix HQ rooms)
3. Consider Synapse workers for federation processing at scale

---

## Common Federation Issues

| Symptom | Likely Cause | Solution |
|---|---|---|
| Can't join rooms on other servers | Port 8448 blocked | Open port 8448 in firewall |
| Other servers can't find you | Well-known not configured | Check `bash scripts/check-well-known.sh` |
| Federation worked, now broken | Certificate expired | Check TLS cert with `make cert-info` |
| Slow federation | Large room syncing | Normal for first join; improves over time |
| Clock-related errors | Server time drift | Sync with NTP: `timedatectl set-ntp true` |
| "Failed to find any servers" | DNS issue | Verify `dig +short example.com` returns your IP |

---

## Disabling Federation

If you want a completely private, isolated homeserver:

1. Set in `.env`:
   ```
   SYNAPSE_FEDERATION_ENABLED=false
   ```

2. Re-process templates and restart:
   ```bash
   bash scripts/init-synapse.sh
   docker compose restart synapse
   ```

3. Optionally, close port 8448 in your firewall.

4. Users on your homeserver will only be able to communicate with other users on the same homeserver.
