SHELL := /bin/bash
.PHONY: help setup init-synapse generate-secrets validate start stop restart \
        restart-synapse pull ps logs logs-synapse logs-traefik logs-postgres \
        status create-admin backup restore check-federation check-well-known \
        cert-info upgrade shell-synapse shell-postgres clean-volumes

# ============================================================
# Colors for pretty output
# ============================================================
RESET   := \033[0m
BOLD    := \033[1m
GREEN   := \033[32m
YELLOW  := \033[33m
CYAN    := \033[36m
RED     := \033[31m

# ============================================================
# Default target: show help
# ============================================================
help:
	@echo ""
	@echo "$(BOLD)$(CYAN)matrix-homeserver — Makefile targets$(RESET)"
	@echo ""
	@echo "$(BOLD)Setup & Configuration$(RESET)"
	@printf "  $(GREEN)%-25s$(RESET) %s\n" "setup"             "Run full bootstrap (first-time setup)"
	@printf "  $(GREEN)%-25s$(RESET) %s\n" "generate-secrets"  "Generate cryptographic secrets into .env"
	@printf "  $(GREEN)%-25s$(RESET) %s\n" "init-synapse"      "Process templates and generate signing key"
	@printf "  $(GREEN)%-25s$(RESET) %s\n" "validate"          "Validate configuration and environment"
	@echo ""
	@echo "$(BOLD)Container Lifecycle$(RESET)"
	@printf "  $(GREEN)%-25s$(RESET) %s\n" "start"             "Start all services (docker compose up -d)"
	@printf "  $(GREEN)%-25s$(RESET) %s\n" "stop"              "Stop all services (docker compose down)"
	@printf "  $(GREEN)%-25s$(RESET) %s\n" "restart"           "Restart all services"
	@printf "  $(GREEN)%-25s$(RESET) %s\n" "restart-synapse"   "Restart only the synapse service"
	@printf "  $(GREEN)%-25s$(RESET) %s\n" "pull"              "Pull latest images"
	@printf "  $(GREEN)%-25s$(RESET) %s\n" "upgrade"           "Safe upgrade: backup, pull, recreate"
	@echo ""
	@echo "$(BOLD)Monitoring & Status$(RESET)"
	@printf "  $(GREEN)%-25s$(RESET) %s\n" "ps"                "List running containers"
	@printf "  $(GREEN)%-25s$(RESET) %s\n" "status"            "Run health check script"
	@printf "  $(GREEN)%-25s$(RESET) %s\n" "logs"              "Follow all service logs"
	@printf "  $(GREEN)%-25s$(RESET) %s\n" "logs-synapse"      "Follow synapse logs"
	@printf "  $(GREEN)%-25s$(RESET) %s\n" "logs-traefik"      "Follow traefik logs"
	@printf "  $(GREEN)%-25s$(RESET) %s\n" "logs-postgres"     "Follow postgres logs"
	@printf "  $(GREEN)%-25s$(RESET) %s\n" "cert-info"         "Show Traefik ACME certificate info"
	@echo ""
	@echo "$(BOLD)Administration$(RESET)"
	@printf "  $(GREEN)%-25s$(RESET) %s\n" "create-admin"      "Create a Matrix admin user"
	@printf "  $(GREEN)%-25s$(RESET) %s\n" "check-federation"  "Verify Matrix federation is working"
	@printf "  $(GREEN)%-25s$(RESET) %s\n" "check-well-known"  "Verify .well-known/matrix endpoints"
	@printf "  $(GREEN)%-25s$(RESET) %s\n" "shell-synapse"     "Open shell in synapse container"
	@printf "  $(GREEN)%-25s$(RESET) %s\n" "shell-postgres"    "Open psql in postgres container"
	@echo ""
	@echo "$(BOLD)Backup & Restore$(RESET)"
	@printf "  $(GREEN)%-25s$(RESET) %s\n" "backup"            "Backup postgres, media, and config"
	@printf "  $(GREEN)%-25s$(RESET) %s\n" "restore"           "Restore from backup (set BACKUP_DIR=...)"
	@echo ""
	@echo "$(BOLD)Danger Zone$(RESET)"
	@printf "  $(RED)%-25s$(RESET) %s\n" "clean-volumes"     "⚠  Destroy all data volumes (IRREVERSIBLE)"
	@echo ""

# ============================================================
# Setup & Configuration
# ============================================================
setup:
	@echo "$(CYAN)Running bootstrap...$(RESET)"
	@bash bootstrap.sh

generate-secrets:
	@echo "$(CYAN)Generating secrets...$(RESET)"
	@bash scripts/generate-secrets.sh

init-synapse:
	@echo "$(CYAN)Initializing Synapse configuration...$(RESET)"
	@bash scripts/init-synapse.sh

validate:
	@echo "$(CYAN)Validating configuration...$(RESET)"
	@bash validate.sh

# ============================================================
# Container Lifecycle
# ============================================================
start:
	@echo "$(CYAN)Starting all services...$(RESET)"
	@docker compose up -d

stop:
	@echo "$(YELLOW)Stopping all services...$(RESET)"
	@docker compose down

restart:
	@echo "$(YELLOW)Restarting all services...$(RESET)"
	@docker compose restart

restart-synapse:
	@echo "$(YELLOW)Restarting synapse...$(RESET)"
	@docker compose restart synapse

pull:
	@echo "$(CYAN)Pulling latest images...$(RESET)"
	@docker compose pull

upgrade:
	@echo "$(CYAN)Running upgrade...$(RESET)"
	@bash upgrade.sh

# ============================================================
# Monitoring & Status
# ============================================================
ps:
	@docker compose ps

status:
	@bash scripts/healthcheck.sh

logs:
	@docker compose logs -f --tail=100

logs-synapse:
	@docker compose logs -f --tail=100 synapse

logs-traefik:
	@docker compose logs -f --tail=100 traefik

logs-postgres:
	@docker compose logs -f --tail=100 postgres

cert-info:
	@echo "$(CYAN)Reading ACME certificate data...$(RESET)"
	@docker compose exec traefik cat /acme/acme.json 2>/dev/null | jq '.' || \
		echo "$(YELLOW)No certificate data yet, or jq not installed.$(RESET)"

# ============================================================
# Administration
# ============================================================
create-admin:
	@echo "$(CYAN)Creating Matrix admin user...$(RESET)"
	@bash scripts/create-admin-user.sh

check-federation:
	@echo "$(CYAN)Checking federation...$(RESET)"
	@bash scripts/check-federation.sh

check-well-known:
	@echo "$(CYAN)Checking .well-known endpoints...$(RESET)"
	@bash scripts/check-well-known.sh

shell-synapse:
	@docker compose exec synapse /bin/bash

shell-postgres:
	@docker compose exec postgres psql -U $${POSTGRES_USER:-synapse} $${POSTGRES_DB:-synapse}

# ============================================================
# Backup & Restore
# ============================================================
backup:
	@echo "$(CYAN)Starting backup...$(RESET)"
	@bash scripts/backup.sh

restore:
	@if [ -z "$(BACKUP_DIR)" ]; then \
		echo "$(RED)Error: BACKUP_DIR is required.$(RESET)"; \
		echo "Usage: make restore BACKUP_DIR=backups/20250101_030000"; \
		exit 1; \
	fi
	@echo "$(YELLOW)Restoring from $(BACKUP_DIR)...$(RESET)"
	@bash scripts/restore.sh "$(BACKUP_DIR)"

# ============================================================
# Danger Zone
# ============================================================
clean-volumes:
	@echo ""
	@echo "$(RED)$(BOLD)⚠  WARNING: This will PERMANENTLY destroy all data volumes!$(RESET)"
	@echo "$(RED)This includes: PostgreSQL database, Redis data, Synapse media, ACME certificates.$(RESET)"
	@echo "$(RED)This action CANNOT be undone. Make sure you have a backup first.$(RESET)"
	@echo ""
	@read -p "Type 'DELETE ALL DATA' to confirm: " confirm; \
	if [ "$$confirm" = "DELETE ALL DATA" ]; then \
		docker compose down -v; \
		echo "$(RED)All volumes destroyed.$(RESET)"; \
	else \
		echo "$(GREEN)Aborted. No data was deleted.$(RESET)"; \
	fi
