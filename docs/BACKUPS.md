# Backup and Restore Guide

## What Is Backed Up

A complete Matrix homeserver backup consists of four components:

| Component | Contents | Criticality |
|---|---|---|
| **PostgreSQL database** | All rooms, messages, users, media metadata, federation data | Critical |
| **Synapse signing key** | Server identity key (`<server_name>.signing.key`) | Critical — if lost, the server loses its identity |
| **Synapse config files** | `homeserver.yaml`, `log.config` | High |
| **Media store** | User-uploaded files, thumbnails, cached federated media | High (cannot be recovered if lost) |

> **Note**: The `.env` file contains all your secrets (passwords, signing keys). It is NOT backed up by default because it is highly sensitive. Consider backing it up separately with encryption (see below).

### What Is NOT in the Backup

- Docker images (re-pulled on restore)
- Traefik ACME certificates (re-issued by Let's Encrypt on first start after restore)
- Redis data (ephemeral cache — reconstructed automatically by Synapse)
- Container logs

---

## Backup Schedule Recommendations

| Frequency | Method | Retention |
|---|---|---|
| Daily | Automated via systemd timer | 30 days |
| Weekly | Copy to off-site storage | 90 days |
| Monthly | Long-term archive | 1 year |

For a busy server (100+ active users), consider running backups every 6 hours for the database, and daily for media.

---

## Manual Backup

```bash
# Run a full backup now
make backup
# or
bash scripts/backup.sh
```

Backups are stored in `backups/<TIMESTAMP>/`:
```
backups/
└── 20250115_030000/
    ├── postgres_20250115_030000.sql.gz       # Database dump
    ├── synapse_config_20250115_030000.tar.gz  # Config + signing key
    ├── synapse_media_20250115_030000.tar.gz   # Media store
    └── MANIFEST.txt                           # File list + checksums
```

### Configuration Options

Set these in `.env` to customize backup behavior:

```bash
BACKUP_ENV=true          # Also back up .env (default: false — sensitive!)
BACKUP_RETENTION_DAYS=30  # Auto-delete backups older than N days (default: 30)
```

---

## Automated Backup with systemd Timer

Install the provided systemd units to run backups automatically at 03:00 daily:

```bash
# Copy service and timer units
sudo cp ops/systemd/matrix-backup.service /etc/systemd/system/
sudo cp ops/systemd/matrix-backup.timer /etc/systemd/system/

# Update WorkingDirectory if not using /opt/matrix:
sudo nano /etc/systemd/system/matrix-backup.service
# Change: WorkingDirectory=/opt/matrix  to match your install path

# Enable and start
sudo systemctl daemon-reload
sudo systemctl enable matrix-backup.timer
sudo systemctl start matrix-backup.timer

# Verify
sudo systemctl status matrix-backup.timer
sudo systemctl list-timers matrix-backup.timer
```

Check backup logs:
```bash
sudo journalctl -u matrix-backup.service -f
sudo journalctl -u matrix-backup.service --since today
```

---

## Backup Retention Policy

The backup script automatically prunes backups older than `BACKUP_RETENTION_DAYS` (default: 30).

To keep more backups:
```bash
# In .env
BACKUP_RETENTION_DAYS=90
```

To disable automatic pruning:
```bash
BACKUP_RETENTION_DAYS=0
```

---

## Off-Site Backup

Local backups protect against data corruption but not against server loss. Always copy backups off-site.

### rsync to remote server

```bash
# Add to a cron job or run after backup.sh
rsync -av --delete \
  /opt/matrix/backups/ \
  user@backup-server:/backups/matrix/
```

### S3-compatible storage (AWS S3, Backblaze B2, etc.)

```bash
# Install aws-cli or rclone
# Example with rclone (configured separately)
rclone sync /opt/matrix/backups/ remote:matrix-backups/

# Or with aws s3
aws s3 sync /opt/matrix/backups/ s3://your-bucket/matrix-backups/
```

### Automating off-site upload

Create `/opt/matrix/scripts/backup-offsite.sh`:
```bash
#!/bin/bash
set -euo pipefail
# Run local backup first
bash /opt/matrix/scripts/backup.sh
# Sync to remote
rclone sync /opt/matrix/backups/ remote:matrix-backups/ --log-file /var/log/matrix-backup-offsite.log
```

---

## Critical Files — Must Back Up

These files are **irreplaceable**:

1. **`data/synapse/<server_name>.signing.key`** — Server identity. If lost, you cannot prove your server's identity to the rest of the Matrix network. Your server would need to re-establish trust with all federated servers.

2. **`.env`** — All secrets. If lost, you can regenerate new secrets but would need to re-process all templates and restart everything.

3. **PostgreSQL database** — All user accounts, rooms, messages, and federation state.

---

## Restore Procedure

### Full Restore (disaster recovery)

```bash
# 1. Clone the repository on the new server
git clone https://github.com/your-org/matrix-homeserver.git /opt/matrix
cd /opt/matrix

# 2. Restore .env (from your off-site backup)
cp /path/to/backed-up/env .env

# 3. Run restore script
bash scripts/restore.sh backups/20250115_030000

# 4. Verify
make status
```

### What the restore script does

1. Stops Synapse
2. Drops and recreates the PostgreSQL database
3. Restores database from the `.sql.gz` dump
4. Restores Synapse config and signing key
5. Restores media store from the volume archive
6. Starts Synapse
7. Waits for health check

### Partial Restore — Database Only

```bash
# Stop Synapse
docker compose stop synapse

# Drop and recreate database
docker compose exec postgres psql -U synapse postgres -c "
  SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='synapse';
  DROP DATABASE synapse;
  CREATE DATABASE synapse ENCODING 'UTF8' LC_COLLATE 'C' LC_CTYPE 'C' TEMPLATE template0;
  GRANT ALL PRIVILEGES ON DATABASE synapse TO synapse;"

# Restore from dump
gunzip -c backups/20250115_030000/postgres_20250115_030000.sql.gz | \
  docker compose exec -T postgres psql -U synapse synapse

# Start Synapse
docker compose start synapse
```

### Partial Restore — Media Only

```bash
# Clear existing media volume
docker run --rm -v matrix-synapse-media:/data alpine sh -c "rm -rf /data/*"

# Restore from archive
docker run --rm \
  -v matrix-synapse-media:/data/media_store \
  -v $(pwd)/backups/20250115_030000/synapse_media_20250115_030000.tar.gz:/backup/media.tar.gz:ro \
  alpine tar -xzf /backup/media.tar.gz -C /
```

---

## Testing Restores

**Test your backups regularly.** An untested backup is not a backup.

Restore testing checklist:
1. Spin up a test server with a different domain
2. Restore the backup
3. Verify users and rooms are present
4. Verify media files are accessible
5. Check Synapse logs for errors
6. Run `make status` and `make check-federation`

Recommended: Test restores monthly.

---

## Recovery Time Objectives

| Scenario | Estimated Recovery Time |
|---|---|
| Synapse crash (no data loss) | 2–5 minutes (restart container) |
| Database corruption (with backup) | 15–30 minutes |
| Full server loss (with recent backup) | 30–60 minutes |
| Signing key loss (no recovery) | Server identity is permanently lost |
| Media loss without backup | Permanent (media cannot be recovered) |

---

## Monitoring Backup Health

Check that backups are running and recent:

```bash
# List most recent backups
ls -la backups/ | tail -10

# Check latest backup timestamp
ls -t backups/ | head -1

# Check systemd timer last run
systemctl status matrix-backup.timer
journalctl -u matrix-backup.service --since "24 hours ago" | tail -20
```

Set up an alert if no backup exists in the last 48 hours.
