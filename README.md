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

> **Estimated time:** 15–30 minutes on a fresh VPS.
> **Skill level:** This guide assumes you can SSH into a Linux server and edit a text file. No prior Docker or Matrix experience required.

---

### Before You Begin — Checklist

Work through this checklist before running a single command. Skipping any item is the most common reason setups fail.

- [ ] You have a **Linux VPS** (Ubuntu 22.04 / Debian 12 recommended) with at least 2 GB RAM and 20 GB disk.
- [ ] You have a **public IPv4 address** for the server. Find it with: `curl -4 https://ifconfig.me`
- [ ] You own a **domain name** (e.g. `example.com`) and can edit its DNS records.
- [ ] **Docker Engine 24+** is installed: `docker --version`
- [ ] The **Docker Compose plugin** is installed: `docker compose version` (note: no hyphen)
- [ ] **Ports 80 and 443 are open** in your firewall/security group. These are required for Let's Encrypt to issue your TLS certificate.
- [ ] Ports **8448, 3478, 5349, and 49152–65535** are open if you want federation and voice/video calls. (See the Prerequisites table above.)

> **Don't have Docker?** Install it with: `curl -fsSL https://get.docker.com | sh`

---

### Step 1 — Clone the Repository onto Your Server

SSH into your server, then run:

```bash
git clone https://github.com/jinzoro/matrix-one-click.git /opt/matrix
cd /opt/matrix
```

**What this does:** Downloads all the configuration files, scripts, and templates into `/opt/matrix`. All future commands are run from this directory.

> If you don't have `git`, install it first: `apt install git` (Debian/Ubuntu) or `yum install git` (RHEL/CentOS).

---

### Step 2 — Create Your DNS Records

> **⚠ Do this BEFORE running bootstrap.** Traefik cannot obtain a TLS certificate until your DNS records are live and pointing at your server.

Log into your domain registrar or DNS provider and create these three **A records**:

| Hostname | Record Type | Value |
|---|---|---|
| `example.com` | A | `your-server-ip` |
| `matrix.example.com` | A | `your-server-ip` |
| `chat.example.com` | A | `your-server-ip` |

Replace `example.com` with your actual domain and `your-server-ip` with your server's public IPv4.

**Wait for DNS to propagate** before continuing. This usually takes 1–5 minutes for most registrars, but can take up to an hour. Verify propagation with:

```bash
# Run these on your server — all three should return your server's IP
dig +short example.com
dig +short matrix.example.com
dig +short chat.example.com
```

If all three commands return your server's IP, you are ready to proceed. If they return nothing or a wrong IP, wait a few more minutes and try again.

> See [docs/DNS.md](docs/DNS.md) for a deeper explanation and optional SRV record setup.

---

### Step 3 — Configure Your Environment File

The `.env` file is where all your personal settings live. Start by copying the example:

```bash
cp .env.example .env
nano .env
```

You need to fill in the following values. Everything else has safe defaults.

```
# ── The three domain names you set up in Step 2 ──────────────────────
MATRIX_SERVER_NAME=example.com          # Your root domain — appears in user IDs
SYNAPSE_HOSTNAME=matrix.example.com     # Where Synapse (the server) runs
ELEMENT_HOSTNAME=chat.example.com       # Where the Element chat app runs
SYNAPSE_PUBLIC_BASEURL=https://matrix.example.com   # Must start with https://

# ── Your email — used for Let's Encrypt certificate expiry notices ────
TRAEFIK_ACME_EMAIL=you@example.com

# ── Strong passwords — use something long and random ─────────────────
POSTGRES_PASSWORD=change_me_to_a_long_random_string
REDIS_PASSWORD=change_me_to_another_long_random_string
COTURN_STATIC_AUTH_SECRET=change_me_to_yet_another_long_random_string

# ── Your server's public IPv4 address (or leave as 'detect') ─────────
COTURN_EXTERNAL_IP=detect
```

**Leave the `SYNAPSE_MACAROON_SECRET_KEY`, `SYNAPSE_FORM_SECRET`, and `SYNAPSE_REGISTRATION_SHARED_SECRET` fields blank.** The next step fills them in automatically.

> #### ⚠ Critical Warning: MATRIX_SERVER_NAME Cannot Be Changed
>
> `MATRIX_SERVER_NAME` is permanently baked into every user ID on your server. If you set it to `example.com`, every user will have an ID like `@alice:example.com`. If you later change it, **all existing accounts and rooms break**. Choose this value carefully and do not change it after first boot.

Save the file and exit (`Ctrl+X` → `Y` → `Enter` in nano).

---

### Step 4 — Generate Cryptographic Secrets

Synapse needs several randomly generated secrets for security. Run:

```bash
bash scripts/generate-secrets.sh
```

**What this does:** Generates three long random strings using `openssl` and writes them directly into your `.env` file. You never need to see or remember these values — they exist only to secure your installation.

Expected output:
```
[OK]    Generated SYNAPSE_MACAROON_SECRET_KEY
[OK]    Generated SYNAPSE_FORM_SECRET
[OK]    Generated SYNAPSE_REGISTRATION_SHARED_SECRET
[OK]    Secrets written to .env
```

If you re-run this script, it will **skip** any secrets that are already set, so it is safe to run multiple times.

---

### Step 5 — Run the Bootstrap Script

This is the main setup command. It wires everything together:

```bash
bash bootstrap.sh
```

The script runs through these stages automatically:

| Stage | What happens |
|---|---|
| Prerequisites check | Confirms Docker, envsubst, curl, and openssl are installed |
| Config validation | Checks all required `.env` values are filled in |
| Template processing | Converts `config/synapse/homeserver.yaml.tpl` → `data/synapse/homeserver.yaml` with your values substituted in |
| Signing key generation | Runs Synapse once in generate mode to create `data/synapse/example.com.signing.key` |
| Database startup | Starts PostgreSQL and waits until it is ready to accept connections |
| Full stack startup | Starts all 7 services with `docker compose up -d` |
| Health polling | Polls each service's health endpoint until everything is green |

The whole process takes **2–5 minutes** on a typical VPS. When it finishes you will see:

```
══ Bootstrap complete ══

  Element Web:  https://chat.example.com
  Synapse API:  https://matrix.example.com
  Federation:   https://matrix.example.com:8448

  Next step: make create-admin
```

> **If bootstrap fails:** Read the error message carefully. The most common causes are:
> - A required `.env` value is still blank or still says `CHANGE_ME`
> - DNS records are not yet propagated (Step 2)
> - Port 80 is blocked by a firewall (Let's Encrypt needs it)
> - Docker is not running (`systemctl start docker`)

---

### Step 6 — Verify Everything Is Running

```bash
make status
```

This runs a health check across all services and prints a PASS/FAIL report:

```
[OK]  traefik       — running, ping endpoint healthy
[OK]  postgres      — running, accepting connections
[OK]  redis         — running, PONG received
[OK]  synapse       — running, /health returned 200
[OK]  element-web   — running, HTTP 200
[OK]  coturn        — running, port 3478 reachable
[OK]  well-known    — running, /.well-known/matrix/client reachable
```

You can also check container status directly:

```bash
docker compose ps
```

And follow logs for any service:

```bash
make logs-synapse    # Synapse logs
make logs-traefik    # Traefik + access logs
make logs            # All services together
```

---

### Step 7 — Create Your First Admin User

User registration is **disabled by default** (a security best practice — you don't want strangers signing up on your server). Create your admin account using the built-in script:

```bash
make create-admin
```

You will be prompted interactively:

```
Enter admin username: alice
Enter password:
Confirm password:

[OK]  Admin user '@alice:example.com' created successfully.
      Log in at: https://chat.example.com
```

> **Important:** Write down your admin username and password somewhere safe. If you lose them, you can create another admin account by running `make create-admin` again.

---

### Step 8 — Access Element Web

Open a browser and go to `https://chat.example.com` (your `ELEMENT_HOSTNAME`).

What you will see on first visit:

1. Element loads and shows a login screen.
2. The homeserver field should already show `matrix.example.com`. If it shows `matrix.org`, your `config.json` was not processed correctly — re-run `bash bootstrap.sh`.
3. Enter the username and password from Step 7.
4. You are now inside your own self-hosted Matrix server.

To invite other people, share your homeserver URL (`https://matrix.example.com`). They can use Element Web at your `chat.example.com`, or any Matrix client (Element desktop, Element mobile, Cinny, FluffyChat, etc.) by setting the homeserver URL.

---

### Step 9 — Verify Federation (Optional but Recommended)

Federation lets your server communicate with other Matrix homeservers, including `matrix.org`. It is enabled by default.

```bash
make check-federation
```

Or use the official Matrix federation tester in your browser:
**https://federationtester.matrix.org/** — enter your `MATRIX_SERVER_NAME` (e.g. `example.com`).

A passing result looks like:
```
[OK]  /.well-known/matrix/server  →  matrix.example.com:443
[OK]  Federation port :8448        →  reachable
[OK]  /_matrix/federation/v1/version  →  {"server": {"name": "Synapse", ...}}
```

If federation is failing, see [docs/FEDERATION.md](docs/FEDERATION.md) for a step-by-step debugging guide.

> To **disable** federation (private server): set `SYNAPSE_FEDERATION_ENABLED=false` in `.env`, then run:
> ```bash
> bash scripts/init-synapse.sh && docker compose restart synapse
> ```

---

### Step 10 — Set Up Automated Daily Backups

Backups run as a systemd timer on the host (not inside Docker). Install it with:

```bash
sudo cp ops/systemd/matrix-backup.service /etc/systemd/system/
sudo cp ops/systemd/matrix-backup.timer /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now matrix-backup.timer
```

Verify the timer is scheduled:

```bash
sudo systemctl status matrix-backup.timer
```

Backups run daily at 03:00 and are saved to `backups/<timestamp>/`. Each backup includes a PostgreSQL dump, your Synapse signing key, and the media store. See [docs/BACKUPS.md](docs/BACKUPS.md) for retention, restore instructions, and off-site backup recommendations.

You can also run a backup manually at any time:

```bash
make backup
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
