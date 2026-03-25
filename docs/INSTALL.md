# Installation Guide

This guide covers the complete installation of the Matrix homeserver stack from scratch.

## Prerequisites

### System Requirements

- **OS**: Ubuntu 22.04 LTS, Debian 12, or any modern Linux distribution
- **RAM**: Minimum 2 GB (4 GB recommended for comfortable operation)
- **CPU**: 2 vCPUs minimum
- **Disk**: 20 GB minimum (media storage grows over time)
- **Public IPv4 address**

### Software Requirements

- **Docker Engine 24+**
  ```bash
  curl -fsSL https://get.docker.com | sh
  sudo usermod -aG docker $USER
  # Log out and back in for group membership to take effect
  ```

- **Docker Compose plugin** (included in Docker Engine 24+)
  ```bash
  docker compose version   # Should print Docker Compose version 2.x
  ```

- **Additional tools**
  ```bash
  # Ubuntu/Debian
  sudo apt install -y curl openssl gettext-base netcat-openbsd jq

  # CentOS/RHEL
  sudo yum install -y curl openssl gettext nmap-ncat jq
  ```

### Domain Requirements

You need a registered domain name that you control. For this guide, we'll use `example.com`.

You need the ability to create DNS A records pointing subdomains to your server's IP.

---

## DNS Records

Create the following DNS records **before** running the bootstrap script. Traefik needs to resolve these hostnames to obtain TLS certificates.

| Hostname | Record Type | Value | Purpose |
|---|---|---|---|
| `example.com` | A | `<your-server-ip>` | Well-known delegation, base domain |
| `matrix.example.com` | A | `<your-server-ip>` | Synapse homeserver API |
| `chat.example.com` | A | `<your-server-ip>` | Element web client |

To find your server's public IP:
```bash
curl -fsSL https://ifconfig.me
```

Wait for DNS propagation before proceeding (typically 5–15 minutes, up to 24 hours for some registrars). Verify with:
```bash
dig +short matrix.example.com
dig +short chat.example.com
dig +short example.com
```

See [DNS.md](DNS.md) for full DNS documentation.

---

## Firewall / Security Group

Open the following ports on your server's firewall or cloud provider security group:

```bash
# Ubuntu/Debian with ufw
sudo ufw allow 80/tcp comment "HTTP (Traefik ACME challenge)"
sudo ufw allow 443/tcp comment "HTTPS"
sudo ufw allow 8448/tcp comment "Matrix federation"
sudo ufw allow 3478/udp comment "TURN/STUN"
sudo ufw allow 3478/tcp comment "TURN/STUN"
sudo ufw allow 5349/udp comment "TURN/STUN TLS"
sudo ufw allow 5349/tcp comment "TURN/STUN TLS"
sudo ufw allow 49152:65535/udp comment "TURN media relay"
sudo ufw enable
```

```bash
# CentOS/RHEL with firewalld
sudo firewall-cmd --permanent --add-port=80/tcp
sudo firewall-cmd --permanent --add-port=443/tcp
sudo firewall-cmd --permanent --add-port=8448/tcp
sudo firewall-cmd --permanent --add-port=3478/udp
sudo firewall-cmd --permanent --add-port=3478/tcp
sudo firewall-cmd --permanent --add-port=5349/udp
sudo firewall-cmd --permanent --add-port=5349/tcp
sudo firewall-cmd --permanent --add-port=49152-65535/udp
sudo firewall-cmd --reload
```

---

## Step-by-Step Installation

### Step 1: Clone the repository

```bash
git clone https://github.com/your-org/matrix-homeserver.git /opt/matrix
cd /opt/matrix
```

### Step 2: Copy and edit the environment file

```bash
cp .env.example .env
nano .env
```

Fill in the following values at minimum:

```bash
MATRIX_SERVER_NAME=example.com           # Your Matrix identity domain
SYNAPSE_HOSTNAME=matrix.example.com      # Synapse hostname
ELEMENT_HOSTNAME=chat.example.com        # Element Web hostname
SYNAPSE_PUBLIC_BASEURL=https://matrix.example.com  # Full Synapse URL
TRAEFIK_ACME_EMAIL=admin@example.com     # Email for Let's Encrypt
POSTGRES_PASSWORD=your-strong-db-password
REDIS_PASSWORD=your-strong-redis-password
COTURN_STATIC_AUTH_SECRET=your-coturn-secret
COTURN_EXTERNAL_IP=your.server.ip.address  # Or 'detect' for auto-detection
```

> **Warning**: `MATRIX_SERVER_NAME` cannot be changed after the first run. Choose it carefully.

### Step 3: Generate cryptographic secrets

```bash
bash scripts/generate-secrets.sh
```

This generates `SYNAPSE_MACAROON_SECRET_KEY`, `SYNAPSE_FORM_SECRET`, and `SYNAPSE_REGISTRATION_SHARED_SECRET` in `.env`.

### Step 4: Validate configuration

```bash
bash validate.sh
```

Fix any `[FAIL]` items before continuing.

### Step 5: Run bootstrap

```bash
bash bootstrap.sh
```

Bootstrap will:
- Process all configuration templates
- Generate the Synapse signing key
- Start all containers
- Wait for health checks to pass

This step typically takes 2–5 minutes on the first run (image downloads, Synapse database migrations, certificate acquisition).

### Step 6: Verify the stack

```bash
make status
# or
bash scripts/healthcheck.sh
```

All services should show `[PASS]`.

### Step 7: Create the first admin user

```bash
make create-admin
# or
bash scripts/create-admin-user.sh
```

Enter a username and password. You'll use these to log into Element.

### Step 8: Access Element Web

Open your browser and navigate to `https://chat.example.com`.

Log in with the admin credentials you created.

### Step 9: Verify federation (if enabled)

```bash
make check-federation
```

Or check at https://federationtester.matrix.org/

### Step 10: Set up automated backups

```bash
sudo cp ops/systemd/matrix-backup.service /etc/systemd/system/
sudo cp ops/systemd/matrix-backup.timer /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now matrix-backup.timer
sudo systemctl status matrix-backup.timer
```

---

## Post-Install Verification

Run these commands to verify everything is working:

```bash
# Check all containers are healthy
docker compose ps

# Check Synapse client endpoint
curl -fsSL https://matrix.example.com/_matrix/client/versions | jq '.versions'

# Check well-known delegation
curl -fsSL https://example.com/.well-known/matrix/client | jq .
curl -fsSL https://example.com/.well-known/matrix/server | jq .

# Check federation endpoint
curl -fsSL https://matrix.example.com/_matrix/federation/v1/version | jq .

# Check Element is reachable
curl -I https://chat.example.com/
```

---

## Creating Additional Admin Users

```bash
bash scripts/create-admin-user.sh another-admin
```

Or using the Synapse Admin API (requires an existing admin access token):

```bash
# Get your access token from Element: Settings → Help & About → Access Token
ACCESS_TOKEN="your-access-token"

# Create user via admin API
curl -fsSL -X PUT \
  -H "Authorization: Bearer ${ACCESS_TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{"password": "strong-password", "admin": true}' \
  "https://matrix.example.com/_synapse/admin/v2/users/@newuser:example.com"
```

---

## Accessing Element

Element Web is available at `https://chat.example.com`.

Users on other Matrix clients can connect by setting the homeserver URL to `https://matrix.example.com`.

Your Matrix ID will be: `@yourusername:example.com`

---

## Troubleshooting Installation

If bootstrap fails:

1. Check Docker logs: `docker compose logs`
2. Run `bash validate.sh` to check configuration
3. Check DNS is resolving: `dig +short matrix.example.com`
4. Check ports are open: `nc -zv your-server-ip 443`
5. See [TROUBLESHOOTING.md](TROUBLESHOOTING.md)
