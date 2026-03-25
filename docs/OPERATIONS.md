# Operations Guide

Day-to-day operations reference for the Matrix homeserver stack.

## Daily Operations

### Starting and Stopping

```bash
# Start all services
make start
# or
docker compose up -d

# Stop all services (containers removed, volumes preserved)
make stop
# or
docker compose down

# Restart all services
make restart
# or
docker compose restart

# Restart a specific service
make restart-synapse
docker compose restart synapse
docker compose restart traefik
docker compose restart postgres
```

### Viewing Logs

```bash
# All services (last 100 lines, follow)
make logs
docker compose logs -f --tail=100

# Specific service
make logs-synapse
make logs-traefik
make logs-postgres
docker compose logs -f --tail=100 coturn

# Without following (dump and exit)
docker compose logs --tail=200 synapse

# With timestamps
docker compose logs -f -t synapse
```

### Container Status

```bash
# Quick status overview
make ps
docker compose ps

# Detailed health check
make status
bash scripts/healthcheck.sh
```

---

## Monitoring Health

### Service Health Endpoints

| Service | Health Check |
|---|---|
| Synapse | `http://localhost:8008/health` (inside container) |
| Traefik | `http://localhost:80/ping` |
| PostgreSQL | `pg_isready -U synapse` |
| Redis | `redis-cli ping` |
| Element | HTTP GET `/` returns 200 |
| Well-known | HTTP GET `/.well-known/matrix/client` returns JSON |

### Running Health Checks

```bash
# Full health check script
bash scripts/healthcheck.sh

# Manual checks
docker compose exec synapse curl -fsSL http://localhost:8008/health
docker compose exec postgres pg_isready -U synapse
docker compose exec redis redis-cli -a "${REDIS_PASSWORD}" ping
```

### Checking Synapse Status

```bash
# Get Synapse version
curl -fsSL https://matrix.example.com/_matrix/client/versions | jq '.versions'

# Check number of users
ACCESS_TOKEN="your-admin-token"
curl -fsSL -H "Authorization: Bearer ${ACCESS_TOKEN}" \
  "https://matrix.example.com/_synapse/admin/v2/users?limit=5" | jq '.total'

# Check number of rooms
curl -fsSL -H "Authorization: Bearer ${ACCESS_TOKEN}" \
  "https://matrix.example.com/_synapse/admin/v1/rooms?limit=5" | jq '.total_rooms'
```

---

## TLS Certificates

Traefik automatically manages TLS certificates via Let's Encrypt ACME. Certificates are renewed automatically before expiry.

### Viewing Certificate Information

```bash
# View raw ACME JSON (requires jq)
make cert-info
docker compose exec traefik cat /acme/acme.json | jq '.letsencrypt.Certificates[] | {domain: .domain, expiry: .certificate}' 2>/dev/null

# Check certificate expiry from outside
echo | openssl s_client -connect matrix.example.com:443 2>/dev/null | \
  openssl x509 -noout -dates

# Check from browser: look for the padlock icon in your browser
```

### Certificate Renewal

Traefik renews certificates automatically 30 days before expiry. No manual intervention is needed.

If renewal fails:
1. Ensure port 80 is accessible from the internet (HTTP challenge)
2. Ensure DNS resolves correctly
3. Check Traefik logs: `docker compose logs traefik | grep -i acme`
4. Check Let's Encrypt rate limits: https://letsencrypt.org/docs/rate-limits/

---

## Log Locations

| Log | Location |
|---|---|
| Traefik access log | Docker volume `matrix-traefik-logs` (inside container: `/var/log/traefik/access.log`) |
| Traefik error log | Docker volume `matrix-traefik-logs` (inside container: `/var/log/traefik/traefik.log`) |
| Synapse application log | `data/synapse/logs/homeserver.log` (rotated daily, 7 days) |
| PostgreSQL | Docker stdout (use `docker compose logs postgres`) |
| Redis | Docker stdout |

### Accessing Traefik Access Logs

```bash
# Open shell in Traefik container
docker compose exec traefik sh

# Tail access log
docker compose exec traefik tail -f /var/log/traefik/access.log

# View last 100 entries
docker compose exec traefik tail -100 /var/log/traefik/access.log
```

---

## Resource Monitoring

```bash
# Real-time resource usage
docker stats

# Disk usage by Docker volumes
docker system df -v

# Database size
docker compose exec postgres psql -U synapse synapse -c \
  "SELECT pg_size_pretty(pg_database_size('synapse')) AS db_size;"

# Media store size (named volume)
docker run --rm -v matrix-synapse-media:/data alpine du -sh /data

# Show largest tables in Synapse DB
docker compose exec postgres psql -U synapse synapse -c "
  SELECT
    relname AS table_name,
    pg_size_pretty(pg_total_relation_size(oid)) AS total_size
  FROM pg_class
  WHERE relkind = 'r'
  ORDER BY pg_total_relation_size(oid) DESC
  LIMIT 10;"
```

---

## User Management

### Creating Users

```bash
# Create admin user (interactive)
bash scripts/create-admin-user.sh

# Create regular user via registration shared secret
docker compose exec synapse register_new_matrix_user \
  -c /data/homeserver.yaml \
  -u newuser \
  -p 'password' \
  --no-admin \
  http://localhost:8008
```

### Managing Users via Admin API

```bash
# Set access token
ACCESS_TOKEN="your-admin-access-token"
BASE_URL="https://matrix.example.com"

# List all users
curl -H "Authorization: Bearer ${ACCESS_TOKEN}" \
  "${BASE_URL}/_synapse/admin/v2/users?limit=100" | jq '.users[].name'

# Deactivate a user
curl -X PUT \
  -H "Authorization: Bearer ${ACCESS_TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{"deactivated": true}' \
  "${BASE_URL}/_synapse/admin/v2/users/@baduser:example.com"

# Reset a user's password
curl -X POST \
  -H "Authorization: Bearer ${ACCESS_TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{"new_password": "new-password", "logout_devices": true}' \
  "${BASE_URL}/_synapse/admin/v1/reset_password/@user:example.com"

# List user devices
curl -H "Authorization: Bearer ${ACCESS_TOKEN}" \
  "${BASE_URL}/_synapse/admin/v2/users/@user:example.com/devices" | jq .
```

---

## Room Management

```bash
ACCESS_TOKEN="your-admin-access-token"
BASE_URL="https://matrix.example.com"

# List all rooms (paginated)
curl -H "Authorization: Bearer ${ACCESS_TOKEN}" \
  "${BASE_URL}/_synapse/admin/v1/rooms?limit=100" | jq '.rooms[] | {id: .room_id, name: .name, members: .joined_members}'

# Get details about a specific room
curl -H "Authorization: Bearer ${ACCESS_TOKEN}" \
  "${BASE_URL}/_synapse/admin/v1/rooms/!roomid:example.com" | jq .

# List room members
curl -H "Authorization: Bearer ${ACCESS_TOKEN}" \
  "${BASE_URL}/_synapse/admin/v1/rooms/!roomid:example.com/members" | jq '.members'

# Delete a room
curl -X DELETE \
  -H "Authorization: Bearer ${ACCESS_TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{"purge": true}' \
  "${BASE_URL}/_synapse/admin/v2/rooms/!roomid:example.com"
```

---

## Media Purge

Over time, cached media from federated servers can grow very large.

```bash
ACCESS_TOKEN="your-admin-access-token"
BASE_URL="https://matrix.example.com"

# Purge remote media cache older than 30 days
curl -X POST \
  -H "Authorization: Bearer ${ACCESS_TOKEN}" \
  "${BASE_URL}/_synapse/admin/v1/purge_media_cache?before_ts=$(date -d '30 days ago' +%s)000"

# Get media info for a user
curl -H "Authorization: Bearer ${ACCESS_TOKEN}" \
  "${BASE_URL}/_synapse/admin/v1/users/@user:example.com/media" | jq .

# Delete specific media
curl -X DELETE \
  -H "Authorization: Bearer ${ACCESS_TOKEN}" \
  "${BASE_URL}/_synapse/admin/v1/media/example.com/MEDIAID"
```

---

## Restarting Individual Services

When restarting services, order matters:

```bash
# Safe restart order (if restarting multiple services):
# 1. Traefik (proxy — can restart without affecting backend)
# 2. Well-known, Element (stateless — instant restart)
# 3. Redis (short downtime acceptable)
# 4. Synapse (stops accepting connections; restart quickly)
# 5. PostgreSQL (restart only during maintenance window)

# Restart Synapse only (most common)
docker compose restart synapse

# Restart Traefik only (to pick up new config)
docker compose restart traefik

# Zero-downtime config reload for Traefik:
# Just update the config files — Traefik watches them with providers.file.watch=true
```

---

## Database Maintenance

```bash
# Connect to postgres
docker compose exec postgres psql -U synapse synapse

# Run VACUUM ANALYZE (reclaim space, update statistics)
docker compose exec postgres psql -U synapse synapse -c "VACUUM ANALYZE;"

# Check for bloated tables
docker compose exec postgres psql -U synapse synapse -c "
  SELECT
    schemaname,
    relname,
    n_live_tup,
    n_dead_tup,
    last_vacuum,
    last_autovacuum
  FROM pg_stat_user_tables
  ORDER BY n_dead_tup DESC
  LIMIT 10;"

# Check active connections
docker compose exec postgres psql -U synapse synapse -c "
  SELECT count(*), state
  FROM pg_stat_activity
  WHERE datname = 'synapse'
  GROUP BY state;"
```

---

## Docker Volume Management

```bash
# List all volumes used by this stack
docker volume ls | grep matrix

# Inspect a volume
docker volume inspect matrix-synapse-media

# Check volume sizes (approximate)
docker run --rm -v matrix-postgres-data:/data alpine du -sh /data
docker run --rm -v matrix-synapse-media:/data alpine du -sh /data
docker run --rm -v matrix-traefik-acme:/data alpine du -sh /data
```

---

## Updating Configuration

When you need to update Synapse configuration:

1. **Edit the template**: `config/synapse/homeserver.yaml.tpl`
2. **Re-process the template**:
   ```bash
   bash scripts/init-synapse.sh
   ```
3. **Restart Synapse**:
   ```bash
   docker compose restart synapse
   ```
4. **Verify** Synapse started correctly:
   ```bash
   docker compose logs --tail=50 synapse
   ```

For Traefik dynamic configuration (middlewares, TLS options):
- Edit files in `config/traefik/dynamic/`
- Traefik reloads automatically (no restart needed)

For Element Web configuration:
- Edit `config/element/config.json`
- Restart Element: `docker compose restart element-web`

---

## Synapse Admin API Overview

The full Synapse Admin API reference is available at:
https://element-hq.github.io/synapse/latest/admin_api/

Key endpoints:

| Endpoint | Method | Purpose |
|---|---|---|
| `/_synapse/admin/v2/users` | GET | List all users |
| `/_synapse/admin/v2/users/{userId}` | GET/PUT | Get or modify user |
| `/_synapse/admin/v1/rooms` | GET | List all rooms |
| `/_synapse/admin/v2/rooms/{roomId}` | DELETE | Delete a room |
| `/_synapse/admin/v1/reset_password/{userId}` | POST | Reset password |
| `/_synapse/admin/v1/purge_media_cache` | POST | Purge federated media |
| `/_synapse/admin/v1/server_version` | GET | Server version info |

All admin API requests require an admin user's access token in the `Authorization: Bearer <token>` header.
