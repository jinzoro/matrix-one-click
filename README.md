# matrix-homeserver — Production Matrix/Element Self-Hosted Stack

[![Docker](https://img.shields.io/badge/Docker-24%2B-2496ED?logo=docker&logoColor=white)](https://docs.docker.com/)
[![Matrix](https://img.shields.io/badge/Matrix-Synapse-000000?logo=matrix&logoColor=white)](https://matrix.org/)
[![License](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)

## Overview

This repository provides a complete, production-quality self-hosted [Matrix](https://matrix.org/) homeserver stack using [Synapse](https://github.com/element-hq/synapse), [Element Web](https://github.com/element-hq/element-web), [Coturn](https://github.com/coturn/coturn), and [Traefik v3](https://traefik.io/) as the reverse proxy. Everything is orchestrated with Docker Compose, templated with shell scripts, and designed to be deployed on any Linux VPS with a public IP address. The stack is opinionated, security-hardened by default (registration disabled, federation optional, TLS enforced), and ships with comprehensive documentation, backup scripts, operational tooling, and a one-command bootstrap flow.

## Why Traefik Instead of Nginx?

Traefik v3 was chosen as the reverse proxy for the following reasons:

- **Native Docker integration** — Traefik reads routing rules directly from container labels, eliminating the need for separate `nginx.conf` files per service and manual reload after adding services.
- **Built-in ACME / Let's Encrypt** — TLS certificates are obtained and renewed automatically with zero additional tooling. No `certbot` cron job, no manual certificate copy step.
- **Dynamic routing without reloads** — Adding or restarting a container updates routing instantly; Traefik never needs a hard reload that would drop connections.
- **Single source of truth** — All routing configuration lives in `compose.yaml` labels and `config/traefik/dynamic/`, making the entire proxy configuration reviewable in one place.
- **Production-grade observability** — Access logs, structured request logging, and a dashboard are built in.

## Architecture

```
                            ┌─────────────────┐
                            │    INTERNET      │
                            └────────┬────────┘
                    :80/:443 ────────┤──────── :8448 (federation)
                                     ▼
              ┌──────────────────────────────────────────────┐
              │           TRAEFIK  (reverse proxy)           │
              │    TLS termination · Let's Encrypt ACME      │
              └──────┬──────────────┬──────────────┬─────────┘
                     │              │              │
           ┌─────────▼──┐  ┌───────▼──────┐  ┌───▼──────────┐
           │ ELEMENT WEB │  │   SYNAPSE    │  │  WELL-KNOWN  │
           │chat.example │  │matrix.example│  │ example.com  │
           │    .com     │  │    .com      │  │  (nginx)     │
           └─────────────┘  └──────┬───────┘  └──────────────┘
                                   │
                    ┌──────────────┼──────────────┐
                    ▼              ▼              ▼
             ┌────────────┐ ┌──────────┐  ┌─────────────┐
             │ POSTGRESQL │ │  REDIS   │  │   COTURN    │
             │   :5432    │ │  :6379   │  │ :3478/:5349 │
             └────────────┘ └──────────┘  └─────────────┘
                                           TURN/STUN (host net)
```

## Services

| Service | Image | Purpose |
|---|---|---|
| `traefik` | `traefik:v3.1` | Reverse proxy, TLS termination, Let's Encrypt ACME |
| `postgres` | `postgres:16-alpine` | Primary database for Synapse |
| `redis` | `redis:7-alpine` | Worker coordination, presence caching, rate limiting |
| `synapse` | `matrixdotorg/synapse:latest` | Matrix homeserver |
| `element-web` | `vectorim/element-web:latest` | Web client UI |
| `coturn` | `coturn/coturn:4.6` | TURN/STUN server for voice and video calls |
| `well-known` | `nginx:1.27-alpine` | Serves `/.well-known/matrix/` delegation files |

## Prerequisites

- **Docker Engine 24+** with the **Docker Compose plugin** (`docker compose` not `docker-compose`)
- A **domain name** you control (e.g. `example.com`)
- A **Linux VPS** with a public IPv4 address
- **Open ports** on your firewall/security group:

| Port | Protocol | Purpose |
|---|---|---|
| 80 | TCP | HTTP (redirected to HTTPS by Traefik) |
| 443 | TCP | HTTPS (Element, Synapse client API, well-known) |
| 8448 | TCP | Matrix federation |
| 3478 | UDP + TCP | TURN/STUN |
| 5349 | UDP + TCP | TURN/STUN over TLS |
| 49152–65535 | UDP | TURN media relay range |

## Directory Structure

```
matrix/
├── bootstrap.sh                  # One-command setup script
├── upgrade.sh                    # Safe upgrade script
├── validate.sh                   # Configuration validation
├── Makefile                      # Convenience targets
├── justfile                      # Just command runner alternative
├── compose.yaml                  # Primary Docker Compose file
├── compose.override.example.yaml # Dev/debug overrides
├── .env.example                  # Environment template (copy to .env)
│
├── config/
│   ├── traefik/
│   │   └── dynamic/
│   │       ├── middlewares.yaml  # Security headers, rate limiting, auth
│   │       └── tls.yaml          # TLS options and cipher suites
│   ├── element/
│   │   └── config.json           # Element Web config (processed by bootstrap.sh)
│   ├── postgres/
│   │   └── init.sql              # DB initialization (runs once on first start)
│   ├── redis/
│   │   └── redis.conf            # Redis configuration
│   ├── synapse/
│   │   ├── homeserver.yaml.tpl   # Synapse config TEMPLATE
│   │   └── log.config.tpl        # Synapse log config TEMPLATE
│   ├── coturn/
│   │   └── turnserver.conf.tpl   # Coturn config TEMPLATE
│   └── well-known/
│       ├── nginx.conf            # Nginx config for well-known service
│       ├── matrix-client.json    # .well-known/matrix/client TEMPLATE
│       └── matrix-server.json    # .well-known/matrix/server TEMPLATE
│
├── data/                         # RUNTIME DATA — gitignored
│   ├── synapse/                  # Processed Synapse config + signing key
│   ├── coturn/                   # Processed Coturn config
│   └── well-known/               # Processed well-known JSON files
│
├── scripts/
│   ├── generate-secrets.sh       # Generate cryptographic secrets into .env
│   ├── init-synapse.sh           # Process templates, generate signing key
│   ├── create-admin-user.sh      # Create first Matrix admin user
│   ├── backup.sh                 # Backup Postgres + media + config
│   ├── restore.sh                # Restore from backup
│   ├── healthcheck.sh            # Check all service health endpoints
│   ├── check-federation.sh       # Verify federation is working
│   ├── check-well-known.sh       # Verify well-known endpoints
│   └── wait-for-it.sh            # TCP readiness helper
│
├── docs/
│   ├── INSTALL.md                # Step-by-step installation guide
│   ├── DNS.md                    # DNS configuration guide
│   ├── OPERATIONS.md             # Day-to-day operations
│   ├── BACKUPS.md                # Backup and restore procedures
│   ├── UPGRADES.md               # Upgrade guide
│   ├── TROUBLESHOOTING.md        # Common issues and solutions
│   ├── SECURITY.md               # Security hardening guide
│   └── FEDERATION.md             # Federation setup and debugging
│
├── ops/
│   └── systemd/
│       ├── matrix-backup.service # Systemd service for automated backups
│       └── matrix-backup.timer   # Systemd timer (daily at 03:00)
│
├── examples/
│   ├── env.minimal.example       # Minimal environment variables
│   └── env.full.example          # Full environment with all options
│
└── backups/                      # Backup output directory (gitignored)
    └── .gitkeep
```

## Quick Start

Follow these 10 steps to get a running Matrix homeserver.

### Step 1: Clone and enter the repository

```bash
git clone https://github.com/your-org/matrix-homeserver.git /opt/matrix
cd /opt/matrix
```

### Step 2: Configure DNS

Point your domain names to the server's public IP **before** running the bootstrap. Traefik needs to obtain TLS certificates via HTTP challenge.

| Hostname | Type | Value |
|---|---|---|
| `example.com` | A | `<your-server-ip>` |
| `matrix.example.com` | A | `<your-server-ip>` |
| `chat.example.com` | A | `<your-server-ip>` |

See [docs/DNS.md](docs/DNS.md) for full DNS configuration options.

### Step 3: Copy and edit the environment file

```bash
cp .env.example .env
nano .env   # or vim .env
```

Fill in at minimum:
- `MATRIX_SERVER_NAME` — your Matrix identity domain (e.g. `example.com`)
- `SYNAPSE_HOSTNAME` — your Synapse hostname (e.g. `matrix.example.com`)
- `ELEMENT_HOSTNAME` — your Element hostname (e.g. `chat.example.com`)
- `SYNAPSE_PUBLIC_BASEURL` — full URL (e.g. `https://matrix.example.com`)
- `TRAEFIK_ACME_EMAIL` — email for Let's Encrypt notifications
- `POSTGRES_PASSWORD` — strong database password
- `REDIS_PASSWORD` — strong Redis password
- `COTURN_STATIC_AUTH_SECRET` — TURN server shared secret
- `COTURN_EXTERNAL_IP` — your server's public IPv4 address (or `detect`)

> **Warning**: `MATRIX_SERVER_NAME` **cannot be changed after first run**. It is baked into all Matrix user IDs (`@alice:example.com`) and the signing key.

### Step 4: Generate cryptographic secrets

```bash
bash scripts/generate-secrets.sh
```

This fills `SYNAPSE_MACAROON_SECRET_KEY`, `SYNAPSE_FORM_SECRET`, and `SYNAPSE_REGISTRATION_SHARED_SECRET` in your `.env` file.

### Step 5: Run the bootstrap script

```bash
bash bootstrap.sh
```

Bootstrap will:
- Validate prerequisites and configuration
- Process all config templates
- Generate the Synapse signing key
- Start all containers
- Wait for health checks to pass

### Step 6: Verify the stack is running

```bash
make status
# or
bash scripts/healthcheck.sh
```

### Step 7: Create your first admin user

```bash
make create-admin
# or
bash scripts/create-admin-user.sh
```

You will be prompted for a username and password.

### Step 8: Access Element Web

Open your browser and navigate to `https://chat.example.com` (replace with your `ELEMENT_HOSTNAME`).

Log in with the admin credentials created in Step 7.

### Step 9: Verify federation (optional)

```bash
make check-federation
# or
bash scripts/check-federation.sh
```

You can also use the Matrix federation tester at: https://federationtester.matrix.org/

### Step 10: Set up automated backups

```bash
sudo cp ops/systemd/matrix-backup.service /etc/systemd/system/
sudo cp ops/systemd/matrix-backup.timer /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now matrix-backup.timer
```

---

## DNS Setup Summary

| Record | Type | Value | Required |
|---|---|---|---|
| `example.com` | A | `<server-ip>` | Yes (well-known delegation) |
| `matrix.example.com` | A | `<server-ip>` | Yes (Synapse) |
| `chat.example.com` | A | `<server-ip>` | Yes (Element) |
| `example.com` | MX | `<mail-server>` | Only if email enabled |

If `matrix.example.com` IS your `MATRIX_SERVER_NAME`, you do not need the well-known service or the base domain A record for Matrix purposes (though you still need the A record for the domain itself).

---

## First Boot

After running `bootstrap.sh`, the following happens automatically:

1. **Postgres** starts and creates the `synapse` database with the correct encoding (`UTF-8`, locale `C`).
2. **Redis** starts with password authentication enabled.
3. **Synapse** starts, connects to Postgres and Redis, runs database migrations, and becomes healthy.
4. **Traefik** starts and requests TLS certificates from Let's Encrypt for all configured hostnames. This may take 30–60 seconds on first boot.
5. **Element Web** becomes available at `https://chat.example.com`.
6. **Coturn** starts on host networking for TURN/STUN.
7. **Well-known** serves delegation files at `https://example.com/.well-known/matrix/`.

Traefik stores certificates in the `traefik-acme` Docker volume. Certificates are automatically renewed before expiry.

---

## Creating the First Admin User

Registration is **disabled by default** for security. Use the shared secret method to create an admin account:

```bash
bash scripts/create-admin-user.sh
```

Or manually:

```bash
docker compose exec synapse register_new_matrix_user \
  -c /data/homeserver.yaml \
  --admin \
  -u youradmin \
  -p 'YourStrongPassword!' \
  http://localhost:8008
```

After creating the admin user, you can manage the server via the Synapse Admin API or install [Synapse Admin UI](https://github.com/Awesome-Technologies/synapse-admin).

---

## Accessing Element

Navigate to `https://chat.example.com` (your `ELEMENT_HOSTNAME`).

On first visit, Element will connect to your homeserver at `https://matrix.example.com`. Log in with the admin credentials you created.

To invite others, share your homeserver URL: `https://matrix.example.com` — users can also use any Matrix client by setting the homeserver to this URL.

---

## Federation

Federation allows your homeserver to communicate with other Matrix homeservers (including `matrix.org`). Federation is **enabled by default** (`SYNAPSE_FEDERATION_ENABLED=true`).

This stack supports two federation methods:

1. **Well-known delegation** (recommended) — `example.com/.well-known/matrix/server` points to `matrix.example.com:443`. This means you can use `example.com` as your Matrix domain while hosting Synapse at `matrix.example.com`.

2. **Direct federation on port 8448** — Traefik listens on `:8448` and routes federation traffic directly to Synapse. This is the fallback if well-known is not available.

Both are configured automatically by this stack.

To disable federation: set `SYNAPSE_FEDERATION_ENABLED=false` in `.env` and run `bash scripts/init-synapse.sh && docker compose restart synapse`.

---

## Backup & Upgrade

### Backup

```bash
make backup
# or
bash scripts/backup.sh
```

Backups are stored in `backups/<timestamp>/` and include:
- PostgreSQL dump (gzipped)
- Synapse config and signing key
- Synapse media store

See [docs/BACKUPS.md](docs/BACKUPS.md) for full documentation.

### Upgrade

```bash
make upgrade
# or
bash upgrade.sh
```

The upgrade script pulls new images, backs up first, and recreates containers in the correct order.

See [docs/UPGRADES.md](docs/UPGRADES.md) for guidance on Synapse major version upgrades.

---

## Security Notes

- **Registration is disabled by default.** Enable it only if you intend to run a public server.
- **TLS 1.2+ is enforced** with strong cipher suites via Traefik's TLS options.
- **Security headers** are applied to all HTTPS responses (HSTS, CSP, X-Frame-Options).
- **Coturn** is configured to deny all RFC1918 and reserved IP ranges to prevent SSRF attacks.
- **Redis** requires password authentication.
- **Database** is on an internal Docker network not exposed to the host.
- **Secrets** (signing key, macaroon secret, etc.) are stored in `data/` which is gitignored.

See [docs/SECURITY.md](docs/SECURITY.md) for the full security guide.

---

## Limitations

- **Single-process Synapse** — This stack runs Synapse as a single process. For large deployments (thousands of users), you will need to configure [Synapse workers](https://element-hq.github.io/synapse/latest/workers.html). Redis is already configured to support workers.
- **No built-in monitoring** — Prometheus metrics are disabled by default. See the future improvements section.
- **No bridges** — Matrix protocol bridges (Telegram, Discord, WhatsApp, etc.) are not included. They can be added as additional services.
- **Media storage** — Media is stored in a Docker volume on the local disk. For large deployments, consider S3-compatible object storage.
- **Single-node only** — This is a single-server deployment. High availability clustering is not in scope.

---

## Future Improvements

- **Matrix bridges** — Add [mautrix](https://github.com/mautrix) bridges for Telegram, Signal, Discord, WhatsApp as additional Compose services.
- **Synapse workers** — Split Synapse into federation sender, media worker, sync worker, etc. for better performance.
- **Prometheus + Grafana** — Enable Synapse metrics endpoint and add monitoring stack.
- **S3 media storage** — Configure `media_storage_providers` in Synapse for object storage.
- **Synapse Admin UI** — Add [Awesome-Technologies/synapse-admin](https://github.com/Awesome-Technologies/synapse-admin) as a service.
- **OIDC / SSO** — Enable single sign-on via Keycloak, Authentik, or another OIDC provider.
- **Fail2ban integration** — Parse Traefik access logs to automatically ban brute-force IPs.

---

## License

MIT License — see [LICENSE](LICENSE) for details.
