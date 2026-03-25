# ============================================================
# Matrix Homeserver Stack — Justfile
# ============================================================
# Install just: https://github.com/casey/just
# Usage:  just <recipe>
#         just help
# ============================================================

set dotenv-load := true
set shell := ["bash", "-c"]

# Show available recipes
default:
    @just --list --unsorted

# ============================================================
# Setup & Configuration
# ============================================================

# Run full bootstrap (first-time setup)
setup:
    @echo "Running bootstrap..."
    bash bootstrap.sh

# Generate cryptographic secrets into .env
generate-secrets:
    @echo "Generating secrets..."
    bash scripts/generate-secrets.sh

# Process templates and generate Synapse signing key
init-synapse:
    @echo "Initializing Synapse configuration..."
    bash scripts/init-synapse.sh

# Validate configuration and environment
validate:
    @echo "Validating configuration..."
    bash validate.sh

# ============================================================
# Container Lifecycle
# ============================================================

# Start all services
start:
    docker compose up -d

# Stop all services
stop:
    docker compose down

# Restart all services
restart:
    docker compose restart

# Restart only the synapse service
restart-synapse:
    docker compose restart synapse

# Pull latest images
pull:
    docker compose pull

# Safe upgrade: backup, pull new images, recreate containers
upgrade:
    bash upgrade.sh

# ============================================================
# Monitoring & Status
# ============================================================

# List running containers and their status
ps:
    docker compose ps

# Run the full health check script
status:
    bash scripts/healthcheck.sh

# Follow all service logs (last 100 lines)
logs:
    docker compose logs -f --tail=100

# Follow synapse logs
logs-synapse:
    docker compose logs -f --tail=100 synapse

# Follow traefik logs
logs-traefik:
    docker compose logs -f --tail=100 traefik

# Follow postgres logs
logs-postgres:
    docker compose logs -f --tail=100 postgres

# Show Traefik ACME certificate JSON (requires jq)
cert-info:
    docker compose exec traefik cat /acme/acme.json | jq '.'

# ============================================================
# Administration
# ============================================================

# Create a new Matrix admin user
create-admin:
    bash scripts/create-admin-user.sh

# Verify Matrix federation is working
check-federation:
    bash scripts/check-federation.sh

# Verify .well-known/matrix endpoints
check-well-known:
    bash scripts/check-well-known.sh

# Open a bash shell in the synapse container
shell-synapse:
    docker compose exec synapse /bin/bash

# Open psql in the postgres container
shell-postgres:
    docker compose exec postgres psql -U "${POSTGRES_USER:-synapse}" "${POSTGRES_DB:-synapse}"

# ============================================================
# Backup & Restore
# ============================================================

# Backup postgres, media, and config
backup:
    bash scripts/backup.sh

# Restore from backup directory (usage: just restore backups/20250101_030000)
restore BACKUP_DIR:
    bash scripts/restore.sh "{{BACKUP_DIR}}"

# ============================================================
# Danger Zone
# ============================================================

# Destroy ALL data volumes (IRREVERSIBLE — requires confirmation)
clean-volumes:
    #!/usr/bin/env bash
    echo ""
    echo "WARNING: This will PERMANENTLY destroy all data volumes!"
    echo "This includes: PostgreSQL, Redis, Synapse media, ACME certificates."
    echo "This action CANNOT be undone."
    echo ""
    read -p "Type 'DELETE ALL DATA' to confirm: " confirm
    if [ "$confirm" = "DELETE ALL DATA" ]; then
        docker compose down -v
        echo "All volumes destroyed."
    else
        echo "Aborted. No data was deleted."
    fi
