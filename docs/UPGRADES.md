# Upgrade Guide

## Philosophy

This stack uses a **controlled, manual upgrade** approach rather than automatic updates. The reasons are:

- **Synapse changelog review**: Synapse occasionally introduces breaking changes, deprecates configuration options, or requires manual migration steps. Always read the changelog before upgrading.
- **Database migrations**: Synapse runs database migrations on startup. These are usually safe but can take significant time on large databases.
- **Backup first**: Every upgrade script runs a backup before pulling new images.
- **Rollback capability**: If something goes wrong, you can restore from the pre-upgrade backup.

---

## Pre-Upgrade Checklist

Before running any upgrade:

- [ ] Read the [Synapse changelog](https://github.com/element-hq/synapse/blob/master/CHANGES.md)
- [ ] Note any breaking changes or required configuration updates
- [ ] Ensure you have a recent backup (`make backup`)
- [ ] Check available disk space (migrations can temporarily double DB size)
- [ ] Plan for a maintenance window (brief downtime during Synapse restart)
- [ ] Notify users if applicable

---

## Checking Current Versions

```bash
# Check running image versions
docker compose images

# Check Synapse version
curl -fsSL https://matrix.example.com/_matrix/client/versions | jq .

# Check federation endpoint version
curl -fsSL https://matrix.example.com/_matrix/federation/v1/version | jq .

# List running container image digests
docker compose ps --format json | jq '.[].Image'
```

---

## Checking for Available Updates

```bash
# See what new images are available (pulls manifest, not image)
docker compose pull --dry-run 2>/dev/null || docker compose pull --quiet

# For specific services
docker pull matrixdotorg/synapse:latest --quiet
docker pull traefik:v3.1 --quiet
docker pull postgres:16-alpine --quiet
```

**Note**: The stack uses `latest` tags for Synapse and Element Web. For production stability, consider pinning to specific versions (e.g., `matrixdotorg/synapse:v1.96.0`) and updating the tag intentionally.

---

## Synapse Breaking Changes — What to Check

When upgrading Synapse, always check:

1. **Config deprecations**: Synapse frequently deprecates old config keys. Check the changelog for "Configuration" sections.

2. **Database migrations**: Some migrations (especially on large servers) can take several minutes. Plan for this downtime.

3. **Python/dependency updates**: Major Synapse versions may update Python requirements in the Docker image.

4. **MSC graduations**: If you're using experimental MSC features, they may have moved to stable with different config keys.

5. **Worker changes**: If you add workers later, ensure the worker configuration matches the Synapse version.

---

## Upgrade Procedure

### Standard Upgrade (using upgrade.sh)

```bash
make upgrade
# or
bash upgrade.sh
```

The upgrade script:
1. Shows a warning and asks for confirmation
2. Runs `bash scripts/backup.sh` (abort if backup fails)
3. Runs `docker compose pull` for all images
4. Stops and recreates services in dependency order:
   - postgres → redis → synapse → element-web → traefik → coturn → well-known
5. Waits for Synapse health check to pass (DB migrations complete)
6. Shows final container status

### Manual Upgrade (step by step)

If you need more control:

```bash
# 1. Back up
bash scripts/backup.sh

# 2. Pull images
docker compose pull

# 3. View what changed
docker compose images

# 4. Upgrade postgres first (in case of PostgreSQL version bump)
docker compose stop postgres
docker compose up -d --no-deps postgres
# Wait for postgres to be healthy
until docker compose exec -T postgres pg_isready -U synapse synapse; do sleep 5; done

# 5. Upgrade redis
docker compose stop redis
docker compose up -d --no-deps redis

# 6. Upgrade Synapse (this runs DB migrations)
docker compose stop synapse
docker compose up -d --no-deps synapse
# Watch migration progress
docker compose logs -f synapse | grep -E "Running upgrade|migration|complete"

# 7. Upgrade remaining services
docker compose up -d --no-deps element-web traefik coturn well-known

# 8. Verify
make status
```

---

## Post-Upgrade Verification

After upgrading, run these checks:

```bash
# 1. All containers healthy
make status

# 2. Synapse API responding
curl -fsSL https://matrix.example.com/_matrix/client/versions | jq '.versions'

# 3. Federation working
make check-federation

# 4. Well-known correct
make check-well-known

# 5. Check Synapse logs for errors
docker compose logs --tail=100 synapse | grep -E "ERROR|CRITICAL|error" || echo "No errors found"

# 6. Verify new version
curl -fsSL https://matrix.example.com/_matrix/federation/v1/version | jq .
```

---

## Rollback Procedure

If the upgrade causes issues:

```bash
# 1. Stop Synapse
docker compose stop synapse

# 2. Restore from pre-upgrade backup
bash scripts/restore.sh backups/<pre-upgrade-timestamp>

# 3. Re-pull the old image (if you know the version)
# Edit compose.yaml to pin the old version, then:
docker compose up -d --no-deps synapse

# 4. Verify
make status
```

**Important**: If Synapse has already run database migrations on the new version, rolling back to the old version may fail because the old version doesn't understand the new database schema. Always back up **before** upgrading.

---

## Postgres Major Version Upgrades

Upgrading PostgreSQL across major versions (e.g., 15 → 16) requires special handling because data files are not forward-compatible.

### Method 1: Dump and restore (recommended)

```bash
# 1. Dump with old version
docker compose exec postgres pg_dump -U synapse synapse > /tmp/synapse_pre_upgrade.sql

# 2. Update compose.yaml to new postgres version
# Edit: image: postgres:16-alpine  (change 16 to 17, etc.)

# 3. Destroy old data volume and recreate
docker compose stop postgres
docker volume rm matrix-postgres-data
docker compose up -d postgres
# Wait for postgres to be ready
until docker compose exec -T postgres pg_isready -U synapse synapse; do sleep 5; done

# 4. Restore
cat /tmp/synapse_pre_upgrade.sql | docker compose exec -T postgres psql -U synapse synapse

# 5. Start Synapse
docker compose up -d synapse
```

### Method 2: pg_upgrade (advanced, faster for large databases)

For large databases where dump/restore would take too long, use `pg_upgrade` inside the PostgreSQL container. This is more complex; consult the PostgreSQL upgrade documentation.

---

## Pinning Versions (Production Recommendation)

For more predictable upgrades, pin image versions in `compose.yaml`:

```yaml
services:
  synapse:
    image: matrixdotorg/synapse:v1.96.0  # pin to specific version

  element-web:
    image: vectorim/element-web:v1.11.50

  traefik:
    image: traefik:v3.1  # Traefik uses semantic versions, pin major.minor

  postgres:
    image: postgres:16-alpine  # pin to major version only
```

Then upgrade by intentionally changing the version tag and running `docker compose pull && docker compose up -d`.

---

## Tracking Versions

Maintain a `VERSIONS.md` file (not committed) with the current deployed versions:

```markdown
# Deployed Versions — Last Updated: 2025-01-15

- Synapse: v1.96.0
- Element Web: v1.11.50
- Traefik: v3.1
- PostgreSQL: 16
- Redis: 7
- Coturn: 4.6
```

Update this after every upgrade.
