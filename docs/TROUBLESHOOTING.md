# Troubleshooting Guide

## Quick Diagnostic Steps

Before diving into specific issues, run these general diagnostics:

```bash
# Check all containers
docker compose ps

# Check recent logs for all services
docker compose logs --tail=50

# Run health check script
bash scripts/healthcheck.sh

# Run configuration validation
bash validate.sh
```

---

## Container Won't Start

### Synapse won't start

**Check logs first:**
```bash
docker compose logs --tail=100 synapse
```

**Common causes:**

1. **`homeserver.yaml` not found or invalid**:
   ```bash
   # Verify it exists
   ls -la data/synapse/homeserver.yaml

   # Re-process template
   bash scripts/init-synapse.sh
   ```

2. **Signing key not found**:
   ```bash
   ls -la data/synapse/*.signing.key
   # If missing:
   bash scripts/init-synapse.sh
   ```

3. **Database connection failed**:
   ```bash
   # Check postgres is running and healthy
   docker compose ps postgres
   docker compose exec postgres pg_isready -U synapse synapse
   ```
   Verify `POSTGRES_PASSWORD`, `POSTGRES_USER`, `POSTGRES_DB` in `.env` match the database.

4. **Wrong file permissions on data/synapse**:
   ```bash
   sudo chown -R 991:991 data/synapse
   docker compose restart synapse
   ```

5. **Configuration error** (syntax or invalid value):
   ```bash
   # Run Synapse config check
   docker compose run --rm synapse check
   # or
   docker run --rm \
     -v $(pwd)/data/synapse:/data \
     matrixdotorg/synapse:latest check
   ```

### PostgreSQL won't start

```bash
docker compose logs postgres
```

**Common causes:**
- `POSTGRES_DB`, `POSTGRES_USER`, `POSTGRES_PASSWORD` changed after initial run
- Data volume from a different PostgreSQL version (major version mismatch)
- Corrupt data files (restore from backup)

### Redis won't start

```bash
docker compose logs redis
```

**Common causes:**
- Redis config syntax error in `config/redis/redis.conf`
- Port conflict (another Redis already running on host with `network_mode: host`)

### Traefik won't start

```bash
docker compose logs traefik
```

**Common causes:**
- Port 80 or 443 already in use:
  ```bash
  sudo ss -tlpn | grep -E ':80|:443'
  sudo lsof -i :80 -i :443
  ```
- Docker socket not accessible
- Invalid dynamic config in `config/traefik/dynamic/`

---

## Can't Connect to Homeserver

### "Unable to connect to homeserver" in Element

1. **Check Synapse is running**:
   ```bash
   curl -fsSL https://matrix.example.com/_matrix/client/versions
   ```

2. **Check TLS certificate** (Traefik may still be acquiring it):
   ```bash
   echo | openssl s_client -connect matrix.example.com:443 2>/dev/null | openssl x509 -noout -dates
   ```
   If the cert is invalid, check Traefik ACME logs:
   ```bash
   docker compose logs traefik | grep -i acme
   ```

3. **Check DNS resolution**:
   ```bash
   dig +short matrix.example.com
   ```

4. **Check `config/element/config.json`** has the correct `base_url`:
   ```bash
   cat config/element/config.json | grep base_url
   ```

5. **Check CORS** — if accessing Element from a different domain, ensure Synapse allows cross-origin requests (should work by default with Traefik handling TLS).

---

## Federation Not Working

```bash
# Run the federation check script
bash scripts/check-federation.sh

# Check federation tester
# https://federationtester.matrix.org/#example.com
```

**Common causes:**

1. **Port 8448 not open**:
   ```bash
   # From another host
   nc -zv your-server-ip 8448
   # Or use nmap
   nmap -p 8448 your-server-ip
   ```

2. **Well-known not configured correctly**:
   ```bash
   bash scripts/check-well-known.sh
   curl -fsSL https://example.com/.well-known/matrix/server
   ```

3. **TLS certificate covers only one hostname, not `MATRIX_SERVER_NAME`**:
   - Traefik should auto-obtain a cert for `MATRIX_SERVER_NAME` via the well-known router
   - Check: `make cert-info`

4. **`SYNAPSE_FEDERATION_ENABLED=false`** in `.env`:
   - Set to `true` and re-run `bash scripts/init-synapse.sh && docker compose restart synapse`

5. **Clock skew** — Matrix federation requires clocks to be synchronized:
   ```bash
   date -u
   # Install and run NTP if needed
   sudo timedatectl set-ntp true
   ```

---

## Well-Known Not Working

```bash
bash scripts/check-well-known.sh
```

**Common causes:**

1. **`data/well-known/client` or `data/well-known/server` doesn't exist**:
   ```bash
   ls -la data/well-known/
   # Re-run bootstrap to process templates
   bash bootstrap.sh
   ```

2. **Well-known container not running**:
   ```bash
   docker compose ps well-known
   docker compose logs well-known
   ```

3. **Traefik not routing `MATRIX_SERVER_NAME` to well-known**:
   - Verify `MATRIX_SERVER_NAME` in `.env` is the base domain (e.g., `example.com`)
   - Check Traefik routing: `docker compose logs traefik | grep well-known`

4. **`MATRIX_SERVER_NAME == SYNAPSE_HOSTNAME`**: If they're the same, you don't need well-known delegation. The well-known service is optional in that case.

---

## TLS Certificate Issues

**Traefik can't obtain Let's Encrypt certificate:**

1. **DNS not resolving**: Wait for DNS propagation first
2. **Port 80 blocked**: Let's Encrypt HTTP challenge requires port 80
   ```bash
   curl -fsSL http://matrix.example.com/ping  # Should redirect to HTTPS
   ```
3. **Rate limited**: Let's Encrypt has rate limits (5 certs per domain per week)
   - Switch to staging temporarily:
     - Add `--certificatesresolvers.letsencrypt.acme.caserver=https://acme-staging-v02.api.letsencrypt.org/directory` to Traefik command
4. **ACME data corrupt**:
   ```bash
   docker volume rm matrix-traefik-acme
   docker compose restart traefik
   ```

---

## Login Failures

**"Incorrect username or password"**:
1. Verify the user exists: use the Synapse Admin API
2. Check password reset is working (requires email to be configured)
3. Try resetting password via admin API

**"Homeserver appears to be offline"**:
- See "Can't Connect to Homeserver" section above

**Rate limited**:
- Synapse rate-limits login attempts
- Check `rc_login` in `homeserver.yaml`
- Temporarily increase burst count if needed

---

## Media Upload Failures

**"Upload failed" or "413 Request Too Large":**

1. **File too large**: Check `SYNAPSE_MAX_UPLOAD_SIZE` in `.env`
2. **Traefik body size limit**: Add to Traefik middleware:
   ```yaml
   # In config/traefik/dynamic/middlewares.yaml
   # Add to the synapse router middleware
   ```
3. **Storage full**: Check disk space:
   ```bash
   df -h
   docker run --rm -v matrix-synapse-media:/data alpine du -sh /data
   ```

---

## TURN Not Working (Voice/Video)

**Voice or video calls fail even within a room:**

1. **Check Coturn is running**:
   ```bash
   docker compose ps coturn
   nc -zv your-server-ip 3478
   nc -zv your-server-ip 5349
   ```

2. **TURN credentials mismatch**:
   - `COTURN_STATIC_AUTH_SECRET` in `.env` must match `static-auth-secret` in `data/coturn/turnserver.conf`
   - `COTURN_REALM` must match `realm` in turnserver.conf
   - After changing, re-run bootstrap and restart coturn

3. **External IP misconfigured**:
   - `data/coturn/turnserver.conf` must have your server's public IP
   - If you used `detect`, verify it detected the correct IP
   - Re-run `bash bootstrap.sh` to re-detect

4. **UDP ports blocked**:
   - Ports 49152–65535 UDP must be open for media relay
   - Coturn uses `network_mode: host` to see real client IPs

5. **Test TURN connectivity**:
   - Use https://webrtc.github.io/samples/src/content/peerconnection/trickle-ice/
   - Add TURN servers from Synapse client API:
     ```bash
     curl -H "Authorization: Bearer <token>" \
       https://matrix.example.com/_matrix/client/v3/voip/turnServer
     ```

---

## High Resource Usage

**Synapse consuming too much CPU:**
- Many small requests hitting rate limits
- Federation from spammy servers: block them in `homeserver.yaml`
- Consider enabling Synapse workers for better CPU distribution

**Synapse consuming too much RAM:**
- Normal for active servers (Synapse caches rooms in RAM)
- Tune caches: add `caches.global_factor: 0.5` to `homeserver.yaml`

**PostgreSQL consuming too much disk:**
- Run media purge (see Operations guide)
- Run `VACUUM FULL` during maintenance window
- Purge old history using retention policies

**Redis OOM**:
- Increase `maxmemory` in `config/redis/redis.conf`
- Default is 256MB, increase to 512MB for busier servers

---

## Database Issues

**"database system identifier differs between pg_ctl and postmaster":**
- PostgreSQL data was from a different installation
- Restore from backup: `bash scripts/restore.sh <backup-dir>`

**"FATAL: role 'synapse' does not exist":**
- Database volume was deleted or is from a different setup
- Recreate: `docker compose down && docker volume rm matrix-postgres-data && docker compose up -d postgres`

**Slow queries:**
```bash
docker compose exec postgres psql -U synapse synapse -c "
  SELECT query, calls, mean_exec_time, total_exec_time
  FROM pg_stat_statements
  ORDER BY total_exec_time DESC
  LIMIT 10;"
```
(Requires `pg_stat_statements` extension; enable in PostgreSQL config if needed.)

---

## Useful Diagnostic Commands

```bash
# Check network connectivity between containers
docker compose exec synapse ping postgres
docker compose exec synapse ping redis

# Check Synapse can reach postgres
docker compose exec synapse python3 -c "
import psycopg2
conn = psycopg2.connect(host='postgres', user='synapse', password='yourpw', dbname='synapse')
print('Database connection: OK')
conn.close()"

# Check Traefik routing table
docker compose exec traefik traefik version

# Inspect Docker networks
docker network inspect matrix-proxy
docker network inspect matrix-backend

# Check which containers are on which networks
docker inspect matrix-synapse | jq '.[0].NetworkSettings.Networks | keys'
docker inspect matrix-traefik | jq '.[0].NetworkSettings.Networks | keys'

# Test SSL certificate manually
openssl s_client -connect matrix.example.com:443 -servername matrix.example.com < /dev/null 2>/dev/null | openssl x509 -noout -text | grep -E "Subject:|DNS:|Not After"
```

---

## Common Error Messages

| Error | Cause | Solution |
|---|---|---|
| `connection refused` to postgres | Postgres not healthy yet | Wait, or run `bash scripts/init-synapse.sh` again |
| `signing_key file is empty` | File exists but is empty | Delete and re-run `bash scripts/init-synapse.sh` |
| `Unknown config option` | Config key deprecated in new Synapse version | Check Synapse upgrade notes |
| `Failed to obtain certificate` | DNS not resolving or port 80 blocked | Fix DNS and firewall |
| `M_FORBIDDEN` from federation | Federation disabled or server blocked | Check `SYNAPSE_FEDERATION_ENABLED` |
| `Database encoding mismatch` | DB not created with `C` locale | Recreate DB with correct encoding |

---

## Fail2ban for Traefik Logs

To protect against brute force attacks, you can configure `fail2ban` to parse Traefik access logs.

Create `/etc/fail2ban/filter.d/traefik-auth.conf`:
```ini
[Definition]
failregex = ^.*"(GET|POST|PUT|DELETE).* 401 .*$
ignoreregex =
```

Create `/etc/fail2ban/jail.d/traefik.conf`:
```ini
[traefik-auth]
enabled = true
filter = traefik-auth
logpath = /var/log/traefik/access.log
maxretry = 5
bantime = 3600
findtime = 600
```

Note: The Traefik access log is inside a Docker volume (`matrix-traefik-logs`). You'll need to mount it as a bind mount or use `docker cp` to access it. Consider mounting the log directory as a bind mount for fail2ban integration.
