# TrackHub Deployment Guide

A comprehensive guide for deploying TrackHub on Linux servers using Docker.

> **First time?** See [QUICKSTART.md](QUICKSTART.md) for a simplified step-by-step guide.

## Table of Contents

1. [Overview](#overview)
2. [Architecture](#architecture)
3. [Prerequisites](#prerequisites)
4. [Quick Start](#quick-start)
5. [Detailed Installation](#detailed-installation)
6. [Configuration Reference](#configuration-reference)
7. [Build Architecture](#build-architecture)
8. [Deployment Scenarios](#deployment-scenarios)
9. [Database Setup](#database-setup)
10. [Migrating to a New Server](#migrating-to-a-new-server-existing-database)
11. [SSL Certificates](#ssl-certificates)
12. [Upgrading From a Previous Version](#upgrading-from-a-previous-version)
13. [Updating Services](#updating-services)
14. [Monitoring & Maintenance](#monitoring--maintenance)
15. [Troubleshooting](#troubleshooting)

---

## Overview

TrackHub is a GPS tracking and monitoring platform consisting of:

| Component | Description | Technology |
|-----------|-------------|------------|
| **TrackHub** | Web frontend | React.js |
| **AuthorityServer** | Identity provider | .NET 10, OpenIddict |
| **TrackHubSecurity** | Security & user management | .NET 10, GraphQL |
| **TrackHub.Manager** | Asset management | .NET 10, GraphQL |
| **TrackHubRouter** | Device routing | .NET 10, GraphQL |
| **TrackHub.Geofencing** | Geofence management | .NET 10, GraphQL |
| **TrackHub.Telemetry** | Position & telemetry store | .NET 10, GraphQL |
| **TrackHub.Reporting** | Reports generation | .NET 10, REST API |
| **SyncWorker** | Background data-sync service | .NET 10, Worker (no HTTP) |
| **nginx** | Reverse proxy, SSL termination | nginx:alpine |
| **db-init** | One-shot **seeder** (data only — never schema) | .NET 10, run once per deploy |

**Document management** is part of **TrackHub.Manager**: uploads, versioning, signatures,
sharing, plus scan/expiration/retention background jobs. Files are stored on the
`manager-documents` Docker volume by default (`DocumentStorage__Provider=LocalFileSystem`),
or in S3 / Azure Blob — see [Configuration Reference](#configuration-reference). Uploads are
capped at **50 MB** by nginx (`client_max_body_size`). This volume is the only stateful data
outside PostgreSQL: back it up separately.

---

## Architecture

### Full Stack Deployment (Single Server)

```
┌─────────────────────────────────────────────────────────────────┐
│                        Linux Server                              │
│  ┌───────────────────────────────────────────────────────────┐  │
│  │                    Nginx (Reverse Proxy)                   │  │
│  │              Port 80 → 443 (SSL Termination)               │  │
│  └────────────────────────┬──────────────────────────────────┘  │
│                           │                                      │
│  ┌────────────────────────┼──────────────────────────────────┐  │
│  │     /              /Identity    /Security    /Manager      │  │
│  │   Frontend         Authority    Security     Manager       │  │
│  │   (React)          (:8080)      (:8080)      (:8080)       │  │
│  └────────────────────────────────────────────────────────────┘  │
│  ┌────────────────────────────────────────────────────────────┐  │
│  │  /Router    /Geofence   /Telemetry   /Reporting            │  │
│  │  Router     Geofencing  Telemetry    Reporting             │  │
│  │  (:8080)    (:8080)     (:8080)      (:8080)               │  │
│  └────────────────────────────────────────────────────────────┘  │
│  ┌────────────────────────────────────────────────────────────┐  │
│  │  SyncWorker (background worker — no HTTP endpoint)          │  │
│  └────────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
                    ┌─────────────────┐
                    │   PostgreSQL    │
                    │  (External DB)  │
                    └─────────────────┘
```

### Split Deployment (Separate Servers)

```
┌──────────────────────┐        ┌──────────────────────┐
│   Frontend Server    │        │   Backend Server     │
│  ┌────────────────┐  │        │  ┌────────────────┐  │
│  │     Nginx      │  │        │  │     Nginx      │  │
│  └───────┬────────┘  │        │  └───────┬────────┘  │
│          │           │        │          │           │
│  ┌───────▼────────┐  │   →    │  ┌───────▼────────┐  │
│  │  React App     │  │  API   │  │  All Backend   │  │
│  │  (Static)      │──┼───────→│  │  Services      │  │
│  └────────────────┘  │ Calls  │  └────────────────┘  │
└──────────────────────┘        └──────────────────────┘
```

---

## Prerequisites

### Server Requirements

| Requirement | Minimum | Recommended |
|-------------|---------|-------------|
| CPU | 2 cores | 4+ cores |
| RAM | 4 GB | 8+ GB |
| Storage | 20 GB | 50+ GB SSD |
| OS | Ubuntu 22.04 LTS | Ubuntu 24.04.4 LTS |

> **Note:** Ubuntu 24.04.4 LTS is the default and recommended operating system. Other Debian-based distributions may work but are not officially tested.

### Software Requirements

| Software | Minimum Version | Recommended |
|----------|----------------|-------------|
| Docker Engine | 24.0+ | Latest stable |
| Docker Compose | v2.20+ | Latest stable |
| Git | 2.34+ | Latest stable |
| OpenSSL | 3.0+ | Latest stable |
| .NET SDK | 10.0 | 10.0 (build only) |

> **Note:** Docker builds include the .NET SDK automatically, but you still need the SDK
> (plus `dotnet-ef`) on a host that can reach PostgreSQL, because **EF migrations are applied
> outside Docker** — see [Applying Migrations](#applying-migrations). Because the
> `TrackHubCommon.*` packages are not published to nuget.org, that host must pack them from
> the `TrackHubCommon/` source into a local feed and register it (the commands are in
> [Applying Migrations](#applying-migrations)). Docker image builds handle this automatically —
> each Dockerfile packs TrackHubCommon in a dedicated `common` stage.

### External Requirements

- Registered domain name (or static IP for internal deployments)
- PostgreSQL 14+ database server (external, already installed and operational)
- SSL certificate (Let's Encrypt recommended for production)

### Database Server Requirements

The deployment assumes an existing PostgreSQL server. Two databases are required:

| Database | Purpose |
|----------|---------|
| `TrackHubSecurity` | Identity, users, roles, policies |
| `TrackHub` | Assets, transporters, devices, geofences, positions |

The PostgreSQL server must be accessible from the application server(s) over the network.

---

## Quick Start

### 1. Install Docker

```bash
# Ubuntu/Debian
curl -fsSL https://get.docker.com -o get-docker.sh
sudo sh get-docker.sh
sudo usermod -aG docker $USER

# Log out and back in, then verify
docker --version
docker compose version
```

### 2. Clone Repositories

```bash
# Create project directory
mkdir -p /opt/trackhub
cd /opt/trackhub

# Clone all required repositories
git clone https://github.com/shernandezp/TrackHub.Deployment.git
git clone https://github.com/shernandezp/TrackHub.git
git clone https://github.com/shernandezp/TrackHub.AuthorityServer.git
git clone https://github.com/shernandezp/TrackHubSecurity.git
git clone https://github.com/shernandezp/TrackHub.Manager.git
git clone https://github.com/shernandezp/TrackHubRouter.git
git clone https://github.com/shernandezp/TrackHub.Geofencing.git
git clone https://github.com/shernandezp/TrackHub.Telemetry.git
git clone https://github.com/shernandezp/TrackHub.Reporting.git
```

> `TrackHubRouter` also provides the **SyncWorker** background service — it has no
> separate repository.

### 3. Configure Environment

```bash
cd TrackHub.Deployment

# Copy example configuration
cp .env.example .env

# Edit configuration (see Configuration Reference section)
nano .env
```

### 4. Make the Scripts Executable

Git does not always preserve the execute bit, and every step below runs a script:

```bash
chmod +x scripts/*.sh
```

### 5. Create the Database Schema (EF migrations)

> ⚠️ **Required on a fresh install.** `db-init` **seeds data only** — it does not create or
> alter tables (see [Database Setup](#database-setup)). Deploying against empty databases
> makes the `db-init` container fail.

Apply migrations for the three services that own them (Telemetry has none — its `telemetry`
schema is created by the Manager migrations).

**Prerequisites on the host running the migrations:**

```bash
# .NET SDK + EF tooling
dotnet tool install --global dotnet-ef

# The services depend on TrackHubCommon.* packages that are NOT on nuget.org and are no
# longer committed as .nupkg files. Pack them from source into a local feed, then register
# it — without this source, restore (and therefore `dotnet ef`) fails.
for p in Domain Application Infrastructure Web; do
  dotnet pack TrackHubCommon/src/Common.$p/Common.$p.csproj -c Release -o /opt/trackhub/local-nuget
done
dotnet nuget add source /opt/trackhub/local-nuget -n trackhub-local
```

Set the connection strings explicitly — **do not rely on the services' `appsettings.json`,
which contains a localhost dev connection string** and would otherwise be used silently:

```bash
cd /opt/trackhub

export SECURITY_CONN="server=db.example.com;port=5432;database=TrackHubSecurity;user id=trackhub;password=YourStrongPassword"
export MANAGER_CONN="server=db.example.com;port=5432;database=TrackHub;user id=trackhub;password=YourStrongPassword"

ConnectionStrings__Security="$SECURITY_CONN" dotnet ef database update \
  --project TrackHubSecurity/src/Infrastructure/SecurityDB --startup-project TrackHubSecurity/src/Web

ConnectionStrings__DefaultConnection="$MANAGER_CONN" dotnet ef database update \
  --project TrackHub.Manager/src/Infrastructure/ManagerDB --startup-project TrackHub.Manager/src/Web

ConnectionStrings__DefaultConnection="$MANAGER_CONN" dotnet ef database update \
  --project TrackHub.Geofencing/src/Infrastructure/ManagerDB --startup-project TrackHub.Geofencing/src/Web

cd /opt/trackhub/TrackHub.Deployment
```

Geofencing requires the `postgis` extension in the `TrackHub` database (see
[Database Setup](#database-setup)).

### 6. Set Up Certificates

```bash
# Obtain Let's Encrypt SSL certificate + generate OpenIddict certificate
# Args: <domain> <letsencrypt-email> [certificate-password]
# Requires DOMAIN and LETSENCRYPT_EMAIL in .env (or pass as arguments)
sudo ./scripts/generate-certs.sh your-domain.com admin@your-domain.com
```

### 7. Configure OAuth Clients

```bash
# Copy and edit clients.json
cp config/clients.json.example config/clients.json
nano config/clients.json

# Update the callback URI with your domain, and set each service client's
# secret to match the matching *_CLIENT_SECRET in .env
```

### 8. Deploy

```bash
# Deploy full stack
./scripts/deploy.sh full --build
```

### 9. Verify Deployment

```bash
# Check health
./scripts/health-check.sh your-domain.com

# View logs
./scripts/logs.sh
```

---

## Detailed Installation

### Step 1: Prepare the Linux Server

```bash
# Update system
sudo apt update && sudo apt upgrade -y

# Install required packages
sudo apt install -y \
    curl \
    git \
    openssl \
    htop \
    ufw

# Configure firewall
sudo ufw allow 22/tcp   # SSH
sudo ufw allow 80/tcp   # HTTP
sudo ufw allow 443/tcp  # HTTPS
sudo ufw enable
```

### Step 2: Install Docker

```bash
# Install Docker
curl -fsSL https://get.docker.com -o get-docker.sh
sudo sh get-docker.sh

# Add current user to docker group
sudo usermod -aG docker $USER

# Start Docker on boot
sudo systemctl enable docker

# Log out and back in
exit
# SSH back in

# Verify installation
docker --version
docker compose version
```

### Step 3: Set Up Project Structure

```bash
# Create directory structure
sudo mkdir -p /opt/trackhub
sudo chown $USER:$USER /opt/trackhub
cd /opt/trackhub

# Clone repositories (as shown in Quick Start)
```

### Step 4: Database Setup

Before deploying, ensure your PostgreSQL database is accessible:

```bash
# Test database connectivity
psql -h your-db-server.com -U postgres -d postgres -c "SELECT version();"
```

See the [Database Setup](#database-setup) section for detailed database initialization instructions.

### Step 5: Configure Environment Variables

Create and configure the `.env` file:

```bash
cd /opt/trackhub/TrackHub.Deployment
cp .env.example .env
```

Edit the file with your configuration:

```bash
nano .env
```

Key configurations to update:

```env
# Domain
DOMAIN=trackhub.example.com
ALLOWED_CORS_ORIGINS=https://trackhub.example.com

# Database  (note: the user field is "user id=" WITH a space — the scripts parse that exact key)
DB_CONNECTION_SECURITY=server=db.example.com;user id=postgres;password=SecurePass123;database=TrackHubSecurity;port=5432
DB_CONNECTION_MANAGER=server=db.example.com;user id=postgres;password=SecurePass123;database=TrackHub;port=5432
DB_CONNECTION_TELEMETRY=server=db.example.com;user id=postgres;password=SecurePass123;database=TrackHub;port=5432
DB_CONNECTION_LOGGING=server=db.example.com;user id=postgres;password=SecurePass123;database=TrackHub;port=5432

# Certificate
CERTIFICATE_PASSWORD=your-cert-password

# Encryption (generate a new GUID)
ENCRYPTION_KEY=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx

# Service-to-service OAuth secrets — no defaults; must match config/clients.json
SYNCWORKER_CLIENT_SECRET=your-syncworker-client-secret
ROUTER_CLIENT_SECRET=your-router-client-secret
SECURITY_CLIENT_SECRET=your-security-client-secret
GEOFENCE_CLIENT_SECRET=your-geofence-client-secret

# Update all REACT_APP_ URLs with your domain
REACT_APP_AUTHORIZATION_ENDPOINT=https://trackhub.example.com/Identity/authorize
# ... etc
```

`DB_CONNECTION_TELEMETRY` and the four `*_CLIENT_SECRET` keys have **no defaults** in
`docker-compose.yml`. Omitting them yields a Telemetry service with an empty connection
string and four service clients that cannot authenticate.

### Step 6: SSL and OpenIddict Certificates

You need **two types of certificates**:
1. **SSL/TLS Certificate** - For HTTPS (Nginx) — obtained from Let's Encrypt
2. **OpenIddict Certificate** - For token signing (Authority Server and all APIs)

#### SSL Certificate (Let's Encrypt)

The `generate-certs.sh` script handles both certificates. Add these to your `.env`:

```env
DOMAIN=trackhub.example.com
LETSENCRYPT_EMAIL=admin@trackhub.example.com
```

Then run:

```bash
sudo ./scripts/generate-certs.sh
```

This will:
- Install `certbot` if not present
- Obtain a free Let's Encrypt certificate (valid 90 days, auto-renewed)
- Generate the OpenIddict `.pfx` certificate for token signing
- Set up a daily cron job that checks for renewal

If nginx is already running, it uses the **webroot** method (zero downtime). Otherwise, it uses **standalone** mode.

**Manual alternative (if not using the script):**

```bash
# Install certbot
sudo apt install -y certbot

# Obtain certificate
sudo certbot certonly --standalone -d trackhub.example.com --email admin@trackhub.example.com --agree-tos

# Copy certificates
sudo cp /etc/letsencrypt/live/trackhub.example.com/fullchain.pem certificates/
sudo cp /etc/letsencrypt/live/trackhub.example.com/privkey.pem certificates/
sudo chown $USER:$USER certificates/*.pem
```

#### OpenIddict Certificate (for Token Signing)

All services (Authority Server, Security, Manager, etc.) use the same OpenIddict certificate to sign and validate tokens. For Linux/Docker deployments, certificates are loaded from a `.pfx` file.

```bash
# Generate OpenIddict certificate (if not using generate-certs.sh)
openssl req -x509 -newkey rsa:4096 \
    -keyout key.pem -out cert.pem \
    -days 365 -nodes \
    -subj "/CN=trackhub.example.com"

# Convert to PFX format
openssl pkcs12 -export \
    -out certificates/certificate.pfx \
    -inkey key.pem -in cert.pem \
    -password pass:your-secure-password

# Clean up
rm key.pem cert.pem

# Update .env with the password
# CERTIFICATE_PASSWORD=your-secure-password
```

**Note:** The `generate-certs.sh` script creates both SSL and OpenIddict certificates in one step.

### Step 7: Configure OAuth Clients

```bash
cp config/clients.json.example config/clients.json
```

Edit `config/clients.json`:

```json
{
  "scopes": [
    {"name": "web_scope", "resource": "trackhub_api"},
    {"name": "mobile_scope", "resource": "trackhub_api"},
    {"name": "driver_mobile_scope", "resource": "trackhub_api"},
    {"name": "service_scope", "resource": "trackhub_api"}
  ],
  "PKCEClients": [
    {
      "clientId": "web_client",
      "uri": "https://trackhub.example.com/authentication/callback",
      "postLogoutUri": "https://trackhub.example.com/authentication/callback",
      "scope": "web_scope"
    },
    {
      "clientId": "mobile_client",
      "uri": "trackhubmobile://callback",
      "postLogoutUri": "trackhubmobile://callback",
      "scope": "mobile_scope"
    },
    {
      "clientId": "driver_mobile_client",
      "uri": "trackhubmobiledriver://callback",
      "postLogoutUri": "trackhubmobiledriver://callback",
      "scope": "driver_mobile_scope"
    }
  ],
  "serviceClients": [
    {"clientId": "syncworker_client", "clientSecret": "generate-a-secure-secret-here", "scope": "service_scope"},
    {"clientId": "router_client",     "clientSecret": "generate-a-secure-secret-here", "scope": "service_scope"},
    {"clientId": "security_client",   "clientSecret": "generate-a-secure-secret-here", "scope": "service_scope"},
    {"clientId": "geofence_client",   "clientSecret": "generate-a-secure-secret-here", "scope": "service_scope"}
  ]
}
```

> **Important:** The `resource` for every scope must be `trackhub_api` (this is the
> token audience the APIs validate). Each service client's `clientSecret` must match the
> `${SYNCWORKER_CLIENT_SECRET}` / `${ROUTER_CLIENT_SECRET}` / `${SECURITY_CLIENT_SECRET}` /
> `${GEOFENCE_CLIENT_SECRET}` values in your `.env`, and `OPENIDDICT_SCOPES` in `.env` must
> list the same scopes (`mobile_scope,driver_mobile_scope,web_scope,service_scope`).

### Step 8: Deploy

```bash
# Full stack deployment
./scripts/deploy.sh full --build

# Monitor deployment
docker compose logs -f
```

### Step 9: Initialize Databases

The database initialization container runs automatically on first deployment. Monitor its progress:

```bash
docker logs -f trackhub-db-init
```

### Step 10: Sync User and Account IDs

The User and Account IDs between the two databases are automatically synchronized during database initialization. However, if you need to run this manually (or re-run it), use the sync script:

```bash
# Run the sync script
./scripts/sync-user-account-ids.sh

# Or run without confirmation prompt
./scripts/sync-user-account-ids.sh --yes
```

**What this script does:**

1. Gets the user ID from `TrackHubSecurity.security.users`
2. Updates `TrackHub.app.users.userid` with the security user ID
3. Updates `TrackHub.app.user_settings.userid` with the security user ID
4. Gets the account ID from `TrackHub.app.accounts`
5. Updates `TrackHubSecurity.security.users.accountid` with the account ID

> The tables are **plural** (`security.users`, `app.users`, `app.accounts`). Older versions
> of this guide used singular names; those relations do not exist.

**Manual sync (if needed):**

If you prefer to sync manually via SQL — run the first two statements against the
**TrackHubSecurity** database and the rest against **TrackHub** (they are separate
databases; you cannot cross-query them in one connection):

```sql
-- In TrackHubSecurity:
SELECT id FROM security.users;
-- Example result: 550e8400-e29b-41d4-a716-446655440000

-- In TrackHub:
SELECT userid FROM app.users;
-- Example result: 11111111-1111-1111-1111-111111111111

UPDATE app.users
SET userid = '550e8400-e29b-41d4-a716-446655440000'
WHERE userid = '11111111-1111-1111-1111-111111111111';

UPDATE app.user_settings
SET userid = '550e8400-e29b-41d4-a716-446655440000'
WHERE userid = '11111111-1111-1111-1111-111111111111';

SELECT accountid FROM app.accounts;
-- Example result: 660e8400-e29b-41d4-a716-446655440000

-- Back in TrackHubSecurity:
UPDATE security.users
SET accountid = '660e8400-e29b-41d4-a716-446655440000'
WHERE id = '550e8400-e29b-41d4-a716-446655440000';
```

### Step 11: Verify Deployment

```bash
# Health check
./scripts/health-check.sh trackhub.example.com

# Test in browser
# https://trackhub.example.com
```

---

## Centralized Configuration Management

All backend services share similar `appsettings.json` configurations. Instead of manually updating each service's configuration file, use the centralized configuration tools.

### Configuration Workflow

1. **Edit the central `.env` file** with all your settings
2. **Run the generator** to create all `appsettings.json` files
3. **Deploy** to source repositories or use directly in Docker

### Generate AppSettings Files

```bash
# Preview all generated configurations (stdout)
./scripts/generate-appsettings.sh

# Generate to a directory for review
./scripts/generate-appsettings.sh --output-dir ./generated

# Generate for a specific service only
./scripts/generate-appsettings.sh --service manager --output-dir ./generated

# Deploy directly to source repository folders
./scripts/generate-appsettings.sh --deploy-to-sources
```

### Full Configuration Sync

The `sync-config.sh` script handles both backend and frontend configuration:

```bash
# Validate your .env configuration
./scripts/sync-config.sh validate

# Show current configuration values
./scripts/sync-config.sh show

# Generate all backend appsettings.json files
./scripts/sync-config.sh generate

# Deploy to all source repositories (backend + frontend .env)
./scripts/sync-config.sh deploy

# Generate only the React .env file
./scripts/sync-config.sh frontend
```

### Configuration Template

The master template at `config/appsettings.template.json` shows all configurable values and their environment variable mappings:

| Variable | Used By | Description |
|----------|---------|-------------|
| `${ALLOWED_CORS_ORIGINS}` | All services | CORS allowed origins |
| `${AUTHORITY_URL}` | All except Authority | Identity provider URL |
| `${DB_CONNECTION_SECURITY}` | Authority, Security | Security database (`TrackHubSecurity`) |
| `${DB_CONNECTION_MANAGER}` | Manager, Geofencing | Manager database (`TrackHub`) |
| `${DB_CONNECTION_TELEMETRY}` | Telemetry | Telemetry DB — **must be the same `TrackHub` database** (schema `telemetry`) |
| `${DB_CONNECTION_LOGGING}` | All backend services | Centralized logging database |
| `${CERTIFICATE_PATH}` | All services | Path to OpenIddict certificate |
| `${CERTIFICATE_PASSWORD}` | All services | Certificate password |
| `${ENCRYPTION_KEY}` | Security, Manager, Router, SyncWorker | Database encryption key |
| `${SECURITY_CLIENT_ID}` / `${SECURITY_CLIENT_SECRET}` | Security | `security_client` service credentials (audit forwarding) |
| `${ROUTER_CLIENT_ID}` / `${ROUTER_CLIENT_SECRET}` | Router | `router_client` service credentials |
| `${SYNCWORKER_CLIENT_ID}` / `${SYNCWORKER_CLIENT_SECRET}` | SyncWorker | `syncworker_client` service credentials |
| `${GEOFENCE_CLIENT_ID}` / `${GEOFENCE_CLIENT_SECRET}` | Geofencing | `geofence_client` service credentials (alert emission + dwell-evaluator job runs toward Manager) |
| `${DOCUMENT_STORAGE_PROVIDER}` / `${DOCUMENT_STORAGE_LOCAL_ROOT}` / `${DOCUMENT_RETENTION_DAYS}` | Manager | Document management storage |
| `${SMTP_*}` / `${WHATSAPP_*}` / `${PORTAL_BASE_URL}` / `${NOTIFICATION_DELIVERY_RETENTION_DAYS}` | Manager | Alerts & notifications delivery channels |
| `${GRAPHQL_*_SERVICE}` | Various | Internal service URLs (includes `GRAPHQL_TELEMETRY_SERVICE`) |
| `AppSettings__Reporting__MaxExportRows` / `__MaxPdfRows` / `__PreviewRows` | Reporting | Report export/preview row limits. Defaults 100000 / 500 / 100 are baked into the template; override at runtime with these env vars — no rebuild needed. |

### When to Regenerate

Regenerate appsettings when you change:
- Domain or URLs
- Database connection strings
- Encryption keys
- Certificate paths or passwords
- Service endpoint URLs

---

## Configuration Reference

### Environment Variables

| Variable | Description | Example |
|----------|-------------|---------|
| `DOMAIN` | Your domain name | `trackhub.example.com` |
| `LETSENCRYPT_EMAIL` | Email for Let's Encrypt | `admin@trackhub.example.com` |
| `ALLOWED_CORS_ORIGINS` | CORS allowed origins | `https://trackhub.example.com` |
| `DB_CONNECTION_SECURITY` | Security DB connection | `server=...;database=TrackHubSecurity;...` |
| `DB_CONNECTION_MANAGER` | Manager DB connection | `server=...;database=TrackHub;...` |
| `DB_CONNECTION_TELEMETRY` | Telemetry DB connection (same `TrackHub` DB) | `server=...;database=TrackHub;...` |
| `DB_CONNECTION_LOGGING` | Centralized logging DB connection | `server=...;database=TrackHub;...` |
| `CERTIFICATE_PASSWORD` | OpenIddict cert password | `your-password` |
| `ENCRYPTION_KEY` | Database encryption key | `GUID format` |
| `AUTHORITY_URL` | Identity provider URL | `https://domain.com/Identity` |
| `OPENIDDICT_SCOPES` | Scopes the Authority registers | `mobile_scope,driver_mobile_scope,web_scope,service_scope` |
| `SYNCWORKER_CLIENT_ID` | SyncWorker OAuth client ID | `syncworker_client` |
| `SYNCWORKER_CLIENT_SECRET` | SyncWorker OAuth client secret | `your-secret` |
| `ROUTER_CLIENT_ID` | Router OAuth client ID | `router_client` |
| `ROUTER_CLIENT_SECRET` | Router OAuth client secret | `your-secret` |
| `SECURITY_CLIENT_ID` | Security OAuth client ID | `security_client` |
| `SECURITY_CLIENT_SECRET` | Security OAuth client secret | `your-secret` |
| `GEOFENCE_CLIENT_ID` | Geofencing OAuth client ID | `geofence_client` |
| `GEOFENCE_CLIENT_SECRET` | Geofencing OAuth client secret | `your-secret` |
| `GRAPHQL_IDENTITY_SERVICE` / `GRAPHQL_SECURITY_SERVICE` | Internal URL of the Security service (both point at the same container) | `http://security:8080/graphql/` |
| `GRAPHQL_MANAGER_SERVICE` / `GRAPHQL_TELEMETRY_SERVICE` / `GRAPHQL_ROUTER_SERVICE` / `GRAPHQL_GEOFENCE_SERVICE` | Internal Docker-network GraphQL URLs for service-to-service calls | `http://manager:8080/graphql/` |
| `REACT_APP_DEFAULT_LAT` / `REACT_APP_DEFAULT_LNG` | Default map center when the user denies location permission | `4.624335` / `-74.063644` |
| `REACT_APP_CLIENT_ID` | Frontend OAuth client id (PKCE client in `clients.json`) | `web_client` |
| `REACT_APP_AUTHORIZATION_ENDPOINT` / `REACT_APP_TOKEN_ENDPOINT` / `REACT_APP_REVOKE_TOKEN_ENDPOINT` / `REACT_APP_LOGOUT_ENDPOINT` | Public OAuth endpoints on the Authority server | `https://domain.com/Identity/authorize` etc. |
| `REACT_APP_CALLBACK_ENDPOINT` | OAuth redirect URI — must match the `web_client` `uri` in `clients.json` | `https://domain.com/authentication/callback` |
| `REACT_APP_MANAGER_ENDPOINT` / `REACT_APP_ROUTER_ENDPOINT` / `REACT_APP_SECURITY_ENDPOINT` / `REACT_APP_GEOFENCING_ENDPOINT` / `REACT_APP_TELEMETRY_ENDPOINT` | Public GraphQL API URLs per service | `https://domain.com/Manager/graphql` |
| `REACT_APP_REPORTING_ENDPOINT` | Public Reporting REST API base URL | `https://domain.com/Reporting/` |
| `DOCUMENT_STORAGE_PROVIDER` | Manager document store (`LocalFileSystem`/`S3`/`AzureBlob`) | `LocalFileSystem` |
| `DOCUMENT_STORAGE_LOCAL_ROOT` | Path inside the container (LocalFileSystem only) | `/app/documents` |
| `DOCUMENT_RETENTION_DAYS` | Byte-retention cleanup horizon | `1825` |
| `PORTAL_BASE_URL` | Portal URL embedded in notification messages | `https://domain.com` |
| `NOTIFICATION_DELIVERY_RETENTION_DAYS` | Notification delivery history retention | `90` |
| `SMTP_HOST` / `SMTP_PORT` / `SMTP_USERNAME` / `SMTP_PASSWORD` / `SMTP_USE_STARTTLS` / `SMTP_FROM_ADDRESS` / `SMTP_FROM_NAME` | Email channel (empty host disables sends; production needs a real relay — external blocker) | empty |
| `WHATSAPP_API_BASE_URL` / `WHATSAPP_PHONE_NUMBER_ID` / `WHATSAPP_ACCESS_TOKEN` / `WHATSAPP_TEMPLATE_NAME` | WhatsApp channel (Meta Cloud API, outbound utility templates; empty ids disable sends — external blocker: verified Meta Business + WABA + approved templates) | empty |

> **`REACT_APP_*` values are baked into the frontend bundle at build time** — changing any of
> them requires rebuilding the frontend image (`./scripts/update-service.sh frontend`), not
> just restarting the container. The `GRAPHQL_*_SERVICE` URLs are internal Docker-network
> addresses; leave them at their defaults unless you rename services in `docker-compose.yml`.

### Document Storage: S3 / Azure Blob

`LocalFileSystem` (the default) needs none of the keys below — documents persist to the
`manager-documents` volume. If you set `DOCUMENT_STORAGE_PROVIDER=S3` or `AzureBlob`, the
**required** keys become mandatory: the Manager throws at startup without them.

| Variable | Required? | Description |
|----------|-----------|-------------|
| `DOCUMENT_S3_BUCKET_NAME` | **Required for S3** | Target bucket |
| `DOCUMENT_S3_REGION` | Optional | AWS region (e.g. `us-east-1`) |
| `DOCUMENT_S3_SERVICE_URL` | Optional | Custom endpoint (MinIO / S3-compatible) |
| `DOCUMENT_S3_ACCESS_KEY` | Optional | Static key; omit both keys to use the default AWS credential chain (IAM role) |
| `DOCUMENT_S3_SECRET_KEY` | Optional | Static secret |
| `DOCUMENT_S3_FORCE_PATH_STYLE` | Optional | Defaults to true when a custom `SERVICE_URL` is set |
| `DOCUMENT_S3_PRESIGNED_EXPIRY_MINUTES` | Optional | Presigned-URL TTL (default `5`) |
| `DOCUMENT_AZURE_CONTAINER_NAME` | **Required for AzureBlob** | Blob container |
| `DOCUMENT_AZURE_CONNECTION_STRING` | **Required for AzureBlob** | Storage account connection string |
| `DOCUMENT_AZURE_SAS_EXPIRY_MINUTES` | Optional | SAS TTL (default `5`) |

Switching provider does **not** migrate existing documents — move the contents of the
`manager-documents` volume to the new backend yourself.

### Service Ports (Internal)

| Service | Internal Port |
|---------|---------------|
| Authority | 8080 |
| Security | 8080 |
| Manager | 8080 |
| Router | 8080 |
| Geofencing | 8080 |
| Telemetry | 8080 |
| Reporting | 8080 |
| SyncWorker | - (background) |

### URL Paths

| Path | Service | Authentication |
|------|---------|----------------|
| `/` | Frontend (React) | Static files — the SPA itself is never authenticated |
| `/status` | Frontend (React) | **Anonymous.** Platform status page — see below |
| `/health` | nginx | Anonymous (static 200) |
| `/health/{service}` | Per-service passthrough | Anonymous |
| `/Identity/*` | Authority Server | Anonymous (it *is* the sign-in surface) |
| `/Security/*` | Security API | Bearer token |
| `/Manager/*` | Manager API | Bearer token, **except** `/Manager/api/PlatformStatus/announcements` |
| `/Router/*` | Router API | Bearer token |
| `/Geofence/*` | Geofencing API | Bearer token |
| `/Telemetry/*` | Telemetry API | Bearer token |
| `/Reporting/*` | Reporting API | Bearer token |

**Deliberately anonymous surfaces.** `/status`, the `/health*` probes, and
`GET /Manager/api/PlatformStatus/announcements` are unauthenticated **by design**: the status page
must answer "is the platform down?" for a user who cannot sign in, which rules out anything behind
the login. The announcements endpoint is rate-limited per client IP, output-cached for 60 s, and
returns only currently-visible announcements — it never exposes drafts, scheduling metadata, or any
account data. Do not put these behind auth or an IP allowlist without removing the status page too.

---

## Build Architecture

### Docker Build Context

All services use the parent directory (`/opt/trackhub/`) as the Docker build context. This allows each Dockerfile to access:

1. **Its own source repository** (e.g., `TrackHub.Manager/`)
2. **The TrackHubCommon source** (`TrackHubCommon/`), packed into NuGet packages by each
   Dockerfile's `common` stage, plus the NuGet feed config (`TrackHub.Deployment/nuget-packages/nuget.config`)
3. **Shared scripts** (`TrackHub.Deployment/scripts/`)

Each Dockerfile has a matching `docker/<Dockerfile>.dockerignore` file that
excludes host build artifacts (`bin/`, `obj/`, `node_modules/`, `build/`, `.git/`)
from the context. This is required for correctness, not just speed: without it,
host-generated `obj/`/`bin/` folders would be copied into the image and overwrite
the container's own restore/compile output, causing `dotnet publish --no-restore`
to treat the code as up-to-date and ship **stale binaries**. Keeping these out of
the context also lets Docker's layer cache detect real source changes, so normal
cached builds always deploy updated code and `--no-cache` is not required.

### Deterministic Updates (No Stale Artifacts)

Updates are designed to always deploy current code without `--no-cache`, repeated
runs, or manual cleanup:

- **Backend / worker images** use ordered layers (`.csproj` → `restore` →
  `COPY src` → `publish`). Because `bin/`/`obj/` are ignored, a source change
  invalidates the `COPY src` layer and forces a real recompile; unchanged code
  reuses the cache safely.
- **Frontend** builds are baked into the image at `/app/dist`. The container
  entrypoint (`docker/frontend-entrypoint.sh`) copies that build into the shared
  `trackhub-frontend` volume on **every start**, and nginx only starts once the
  frontend reports healthy. This fixes the classic named-volume trap where Docker
  populates a volume only when it is first created (empty), leaving nginx serving
  the previous build after a rebuild.
- **`--force-recreate`** guarantees containers are replaced by the freshly built
  images on every deploy.

### TrackHubCommon Packages

TrackHub services depend on the **TrackHubCommon** shared library, which is not published to nuget.org. Rather than committing prebuilt `.nupkg` files, each Dockerfile packs TrackHubCommon from source in a dedicated first build stage (`FROM ... AS common`) that runs `dotnet pack` on the four `Common.*` projects into `/local-nuget`. That output is copied to `/nuget-packages/` alongside `nuget-packages/nuget.config`, which configures both the local source and nuget.org for the restore step.

Because packages are built from the `TrackHubCommon/` source inside the build context on every image build, updating TrackHubCommon requires **no manual repack** — just rebuild the affected services. Bump `<Version>` in `TrackHubCommon/Directory.Build.props` and the matching `TrackHubCommon.*` `PackageVersion` entries in each service's `Directory.Packages.props` in lockstep when you introduce a breaking change.

### Reverse Proxy and HTTPS

Nginx terminates SSL and forwards HTTP requests to backend containers. Each ASP.NET service uses `ForwardedHeaders` middleware to trust `X-Forwarded-Proto` and `X-Forwarded-For` headers from nginx, ensuring the application correctly identifies requests as HTTPS even though internal traffic is HTTP.

---

## Deployment Scenarios

### Scenario 1: Single Server (Full Stack)

Use `docker-compose.yml`:

```bash
./scripts/deploy.sh full --build
```

The deployment script rebuilds images using the Docker layer cache (source
changes are detected automatically), then starts services with
`--force-recreate --no-build` so the running containers come from the freshly
built images. Add `--no-cache` only if you ever need to force a full rebuild.

### Scenario 2: Separate Frontend and Backend

#### Backend Server

```bash
# Copy .env.backend.example to .env
cp .env.backend.example .env
# Edit with backend-specific settings
nano .env

# Deploy backend only
./scripts/deploy.sh backend --build
```

#### Frontend Server

```bash
# Copy .env.frontend.example to .env
cp .env.frontend.example .env
# Edit with frontend-specific settings (pointing to backend server)
nano .env

# Deploy frontend only
./scripts/deploy.sh frontend --build
```

---

## Database Setup

### PostgreSQL Requirements

- PostgreSQL 14+
- Two databases: `TrackHubSecurity` and `TrackHub`
- The **`postgis`** extension in the `TrackHub` database (required by Geofencing —
  its migrations declare `HasPostgresExtension("postgis")`)
- Must be installed and operational before deploying TrackHub

### The Schema Is Created by EF Migrations — Not by `db-init`

This trips people up, so it is worth stating plainly:

| Step | What it does | What it does **not** do |
|------|--------------|--------------------------|
| **EF migrations** (`dotnet ef database update`) | Create and alter all tables/schemas | — |
| **`db-init`** (runs inside `deploy.sh full`) | Seed reference data + OAuth clients (idempotent) | **Does not create or alter any table** |

Both `DBInitializer`s call `SeedAsync()` only. Running `db-init` against an empty database
fails. Apply migrations **first**, on a fresh install *and* on every upgrade that adds them.

### Manual Database Creation

Run as a **superuser** — `CREATE EXTENSION` requires it:

```sql
-- Create databases
CREATE DATABASE "TrackHubSecurity";
CREATE DATABASE "TrackHub";

-- Create user (if needed)
CREATE USER trackhub WITH PASSWORD 'secure_password';
GRANT ALL PRIVILEGES ON DATABASE "TrackHubSecurity" TO trackhub;
GRANT ALL PRIVILEGES ON DATABASE "TrackHub" TO trackhub;

-- PostgreSQL 15+: database-level grants do NOT allow creating objects. The role also needs
-- the public schema, where Serilog auto-creates its "logs" table (needAutoCreateTable).
\c TrackHubSecurity
GRANT ALL ON SCHEMA public TO trackhub;

\c TrackHub
GRANT ALL ON SCHEMA public TO trackhub;

-- PostGIS, in the TrackHub database (superuser required)
CREATE EXTENSION IF NOT EXISTS postgis;
```

### Applying Migrations

Three services own migrations. **Telemetry has none** — its `telemetry` schema is created by
the Manager migrations.

| Service | Migrations project | Startup project | Target DB |
|---------|--------------------|-----------------|-----------|
| Security | `TrackHubSecurity/src/Infrastructure/SecurityDB` | `TrackHubSecurity/src/Web` | `TrackHubSecurity` |
| Manager | `TrackHub.Manager/src/Infrastructure/ManagerDB` | `TrackHub.Manager/src/Web` | `TrackHub` |
| Geofencing | `TrackHub.Geofencing/src/Infrastructure/ManagerDB` | `TrackHub.Geofencing/src/Web` | `TrackHub` |

Pack `TrackHubCommon.*` into a local feed once (they are not on nuget.org and are not
committed as `.nupkg` files), then set the connection strings explicitly — the services'
`appsettings.json` holds a **localhost dev** connection string that EF would otherwise use
silently:

```bash
dotnet tool install --global dotnet-ef

cd /opt/trackhub
for p in Domain Application Infrastructure Web; do
  dotnet pack TrackHubCommon/src/Common.$p/Common.$p.csproj -c Release -o /opt/trackhub/local-nuget
done
dotnet nuget add source /opt/trackhub/local-nuget -n trackhub-local

export SECURITY_CONN="server=db.example.com;port=5432;database=TrackHubSecurity;user id=trackhub;password=YourStrongPassword"
export MANAGER_CONN="server=db.example.com;port=5432;database=TrackHub;user id=trackhub;password=YourStrongPassword"

ConnectionStrings__Security="$SECURITY_CONN" dotnet ef database update \
  --project TrackHubSecurity/src/Infrastructure/SecurityDB --startup-project TrackHubSecurity/src/Web

ConnectionStrings__DefaultConnection="$MANAGER_CONN" dotnet ef database update \
  --project TrackHub.Manager/src/Infrastructure/ManagerDB --startup-project TrackHub.Manager/src/Web

ConnectionStrings__DefaultConnection="$MANAGER_CONN" dotnet ef database update \
  --project TrackHub.Geofencing/src/Infrastructure/ManagerDB --startup-project TrackHub.Geofencing/src/Web
```

### Running Seeders Manually

These **seed only** — they assume the schema already exists (see above).

```bash
# Build and run ClientSeeder
cd /opt/trackhub/TrackHub.AuthorityServer/src/ClientSeeder
dotnet build
dotnet run

# Build and run Security DBInitializer
cd /opt/trackhub/TrackHubSecurity/src/DBInitializer
dotnet build
dotnet run

# Build and run Manager DBInitializer
cd /opt/trackhub/TrackHub.Manager/src/DBInitializer
dotnet build
dotnet run
```

---

## Migrating to a New Server (Existing Database)

If you already have a running TrackHub installation and want to migrate the application services to a new server while keeping your existing database, follow these steps:

### What the db-init Container Does

The `db-init` container runs on **every deploy** and performs:

1. **ClientSeeder** - Upserts the OAuth scopes and clients from `config/clients.json` (idempotent)
2. **Security DBInitializer** - Seeds security resources, roles, and service-client registrations (idempotent)
3. **Manager DBInitializer** - Seeds master data (report catalog, transporter types, master account/user) (idempotent)
4. **Sync User/Account IDs** - One-time foreign-key alignment between the two databases, guarded by a flag file (`db-init-flag` volume)

Steps 1–3 are idempotent: they upsert or skip anything that already exists, so re-running adds any clients/resources present in `config/clients.json` and the seed data while leaving existing rows untouched. Only step 4 is gated by the flag file.

> **Schema vs. seed:** the DBInitializers **seed data only** — they assume the database
> schema already exists. EF Core **schema migrations ("DB updates") are applied separately**
> from `db-init` (see README → *Database Migrations*, applied with your EF migration
> process, e.g. `dotnet ef database update`). Apply migrations for **all** stateful
> services — Security, Manager, **Geofencing** (`geofencing` schema) and the `telemetry`
> schema (owned by Manager migrations) — before or alongside a deploy.

Steps 1–3 are safe to re-run, but **step 4 is a one-time destructive ID sync gated by a
flag file that lives in a volume**. When you move to a *new* server the flag volume starts
empty, so step 4 would run again against your already-synced data. Use one of the options
below to skip it.

### Option 1: Use --skip-init Flag (Recommended)

```bash
./scripts/deploy.sh full --build --skip-init
```

This preserves the normal cached build and forced recreation behavior while skipping database initialization.

### Option 2: Deploy Without db-init Manually

Start all services except db-init:

```bash
# Configure your .env with existing database connection strings
cp .env.example .env
nano .env  # Set DB_CONNECTION_SECURITY and DB_CONNECTION_MANAGER

# Build images (cached; source changes are detected automatically) and deploy without db-init
docker compose build
docker compose up -d --force-recreate --no-build --no-deps nginx frontend authority security manager router geofencing telemetry reporting syncworker
```

### Option 3: Pre-create the Initialization Flag

If you want to use the normal deployment process but skip initialization:

The volume is **prefixed with the Compose project name** (derived from the deployment
directory), so do not guess it — create the stack's volumes first, then look the name up:

```bash
# Create the volumes without starting anything, then find the real flag volume name
docker compose create
docker volume ls | grep db-init-flag        # e.g. trackhubdeployment_db-init-flag

# Mark initialization as already done
docker run --rm -v <that-volume-name>:/flags alpine touch /flags/db-initialized

# Now deploy normally - db-init will detect the flag and skip
./scripts/deploy.sh full --build
```

> Creating a volume named `deployment_db-init-flag` by hand does **not** work — Compose
> mounts a differently-prefixed volume, so db-init would still run the one-time ID sync.

### Option 4: Comment Out db-init in docker-compose.yml

Edit `docker-compose.yml` and comment out the db-init service (note the build context is
the **workspace root**, one level above the deployment folder):

```yaml
# db-init:
#   build:
#     context: ..
#     dockerfile: TrackHub.Deployment/docker/Dockerfile.db-init
#   ...
```

Then remove the dependency from the authority service.

### Migration Checklist

- [ ] Backup existing database before migration
- [ ] Verify PostgreSQL is accessible from new server
- [ ] Copy SSL certificates (`certificates/` folder)
- [ ] Copy OpenIddict certificate (`certificate.pfx`)
- [ ] Update `.env` with correct database connection strings
- [ ] Update `.env` with new server's domain (if changed)
- [ ] Choose one of the skip options above
- [ ] Deploy and verify services connect properly
- [ ] Test authentication flow
- [ ] Test API endpoints

---

## SSL Certificates

### Production (Let's Encrypt)

The recommended way is to use the provided script:

```bash
# Set in .env
# DOMAIN=your-domain.com
# LETSENCRYPT_EMAIL=admin@your-domain.com

# Run the script (handles everything)
sudo ./scripts/generate-certs.sh
```

The script will:
1. Install `certbot` if needed
2. Obtain a free SSL certificate from Let's Encrypt
3. Copy `fullchain.pem` and `privkey.pem` to `certificates/`
4. Generate the OpenIddict `certificate.pfx` for token signing
5. Add a daily cron job for automatic renewal

Certificates are valid for 90 days and renew automatically. The renewal script uses the **webroot** method so nginx stays online during renewal.

```bash
# Manual renewal check
./scripts/renew-ssl.sh

# Verify renewal cron is set up
crontab -l | grep renew-ssl
```

### OpenIddict Certificate (Token Signing)

All services (including the Authority Server) use the `LoadCertFromFile` option to load the OpenIddict certificate from a `.pfx` file. This is the recommended approach for Linux/Docker deployments.

#### Option A: Generate Self-Signed Certificate (Development/Testing)

> Do **not** use `scripts/generate-certs.sh` for this. That script always obtains a real
> Let's Encrypt certificate first (it installs certbot, runs `certonly`, and exits with an
> error if `/etc/letsencrypt/live/<domain>` never appears). It requires a public domain and
> is a production-only path. For a self-signed token-signing certificate, use OpenSSL
> directly:

```bash
openssl req -x509 -newkey rsa:4096 \
    -keyout key.pem -out cert.pem \
    -days 365 -nodes \
    -subj "/CN=your-domain.com"

# Convert to PFX format
openssl pkcs12 -export \
    -out certificates/certificate.pfx \
    -inkey key.pem -in cert.pem \
    -password pass:your-certificate-password

# Clean up temporary files
rm key.pem cert.pem
```

#### Option B: Use CA-Signed Certificate (Production)

1. Obtain a certificate from a trusted Certificate Authority
2. Convert to PFX format if needed:

```bash
# If you have separate cert and key files
openssl pkcs12 -export \
    -out certificates/certificate.pfx \
    -inkey your-private-key.pem \
    -in your-certificate.pem \
    -certfile your-ca-bundle.pem \
    -password pass:your-certificate-password
```

#### Certificate Configuration

The Docker deployment is configured to use file-based certificate loading:

| Environment Variable | Description | Example |
|---------------------|-------------|---------|
| `OpenIddict__LoadCertFromFile` | Enable file-based loading | `true` |
| `OpenIddict__Path` | Path to certificate file | `/app/certificates/certificate.pfx` |
| `OpenIddict__Password` | Certificate password | Set in `.env` as `CERTIFICATE_PASSWORD` |

**Important Notes:**
- All services use the same certificate for token validation
- The certificate is mounted as a read-only volume at `/app/certificates/`
- Set `CERTIFICATE_PASSWORD` in your `.env` file
- For production, use a CA-signed certificate with a strong password

#### Windows vs Linux Certificate Loading

| Platform | Method | Configuration |
|----------|--------|---------------|
| **Linux/Docker** | File-based (PFX) | `LoadCertFromFile=true`, `Path=/app/certificates/certificate.pfx` |
| **Windows (IIS)** | Certificate Store | `LoadCertFromFile=false`, `Thumbprint=<cert-thumbprint>` |

The services support both methods. For Docker deployments, file-based loading is used automatically.

---

## Upgrading From a Previous Version

A version upgrade can introduce new services, new configuration keys, new OAuth
clients, and new database migrations. Because `.env` and `config/clients.json`
are **your local files** (they are not overwritten by `git pull`), you must merge the
new keys into them yourself. Follow these steps in order.

### 1. Back up first

```bash
cd /opt/trackhub/TrackHub.Deployment
./scripts/backup-database.sh backup          # dumps BOTH databases into one archive
cp .env .env.bak
cp config/clients.json config/clients.json.bak

# Uploaded documents are NOT in the database — back the volume up too
docker volume ls | grep manager-documents
docker run --rm -v <volume-name>:/data -v "$PWD/backups:/backup" alpine \
  tar czf /backup/documents-preupgrade.tar.gz -C /data .
```

### 2. Pull the new code (all repos)

**Telemetry is a new repository** — an instance installed before this release does not
have it on disk, and the build (`docker/Dockerfile.telemetry`) copies from
`TrackHub.Telemetry/`. Clone it before anything else, or the deploy fails:

```bash
cd /opt/trackhub
[ -d TrackHub.Telemetry ] || git clone https://github.com/shernandezp/TrackHub.Telemetry.git
```

Then pull the rest using the loop in [Update All Services](#update-all-services).
No new repo is needed for **SyncWorker** — it builds from `TrackHubRouter`.

### 3. Reconcile your `.env` with the template

Compare your live `.env` against the updated example and add anything missing:

```bash
# Show keys present in the template but not in your .env
comm -23 <(grep -oE '^[A-Z0-9_]+=' .env.example | sort -u) \
         <(grep -oE '^[A-Z0-9_]+=' .env | sort -u)
```

Keys that are **new or changed** and required by this release:

| Key | Action |
|-----|--------|
| `ROUTER_CLIENT_ID` / `ROUTER_CLIENT_SECRET` | **Add.** Router now performs service-to-service calls; must match the `router_client` in `clients.json`. |
| `SECURITY_CLIENT_ID` / `SECURITY_CLIENT_SECRET` | **Add.** Security now forwards audit/user writes; must match `security_client`. |
| `DB_CONNECTION_TELEMETRY` | **Add** (same `TrackHub` database as `DB_CONNECTION_MANAGER`). |
| `GRAPHQL_TELEMETRY_SERVICE` | **Add** (`http://telemetry:8080/graphql/`). |
| `REACT_APP_TELEMETRY_ENDPOINT` | **Add** (`https://<domain>/Telemetry/graphql`). |
| `DOCUMENT_STORAGE_PROVIDER` / `DOCUMENT_STORAGE_LOCAL_ROOT` / `DOCUMENT_RETENTION_DAYS` | **Add** (defaults work; documents persist to the `manager-documents` volume). |
| `OPENIDDICT_SCOPES` | **Change** to `mobile_scope,driver_mobile_scope,web_scope,service_scope`. |
| `SYNCWORKER_CLIENT_ID` | **Change** to `syncworker_client`. |
| `GEOFENCE_CLIENT_ID` / `GEOFENCE_CLIENT_SECRET` | **Add**. Geofencing now emits alert events and job runs to Manager; must match the `geofence_client` in `clients.json`. |

### 4. Reconcile `config/clients.json`

Bring your `clients.json` in line with `config/clients.json.example`:

- **scopes:** add `driver_mobile_scope` and `service_scope` (`resource: trackhub_api`); remove any `sec_scope`.
- **PKCEClients:** add `mobile_client` and `driver_mobile_client` if you run the mobile/driver apps.
- **serviceClients:** add `router_client`, `security_client`, and `geofence_client`, and give **every** service client `"scope": "service_scope"`. Each `clientSecret` must equal the matching `*_CLIENT_SECRET` in `.env`.

### 5. Apply database migrations

`db-init` seeds data only — it does **not** create or alter the schema. Apply the EF
Core migrations for every stateful service against your existing databases **before**
starting the new images (Security → `TrackHubSecurity`; Manager and Geofencing →
`TrackHub`; the `telemetry` schema is created by the Manager migrations). Use your
standard migration process (e.g. `dotnet ef database update` per service, or an EF
migration bundle). This step is required on every upgrade that adds migrations.

**Migrations added by recent releases** (apply in order; each is additive and safe to re-run):

| Migration | Service | Adds | If not applied |
|-----------|---------|------|----------------|
| `AddPlatformAnnouncements` | Manager | `app.platform_announcements` (platform status page announcements) | `GET /Manager/api/PlatformStatus/announcements` returns 500 and the announcement banner never appears. The status page itself still works — tiles are probed directly and do not touch this table. |

> **This matters on the code-only paths.** `update-service.sh` and the zero-downtime
> procedure do **not** run migrations. Deploying a Manager image that expects
> `app.platform_announcements` onto a database without it will 500 on the announcements
> endpoint until you run the migration. Verify afterwards with
> `./scripts/health-check.sh <domain>`, which now probes that endpoint.

### 6. Rebuild and deploy

```bash
cd /opt/trackhub/TrackHub.Deployment
./scripts/deploy.sh full --build
```

`deploy.sh full` runs `db-init`, which re-seeds idempotently — registering the new
`router_client`/`security_client` and any new scopes/permissions — and force-recreates
every container (so the Authority picks up the new `OPENIDDICT_SCOPES`). The one-time
User/Account ID sync is skipped because its flag already exists.

### 7. Verify

```bash
./scripts/health-check.sh your-domain.com
```

> **Note:** the per-service and [zero-downtime](#zero-downtime-updates) update paths below
> do **not** run `db-init` and do **not** apply migrations. Use them for code-only updates.
> Any upgrade that adds a migration, a new OAuth client, or a new scope must go through the
> full `deploy.sh full --build` at least once (after steps 3–5).

---

## Updating Services

For code-only updates (no new migrations, clients, or config keys), updates are
deterministic. `deploy.sh` and `update-service.sh` rebuild images with the Docker
layer cache (source changes are detected automatically) and always force-recreate
containers, and the frontend refreshes its static assets on every start. You do
**not** need `--no-cache`, repeated executions, or manual volume/repo cleanup. Pass
`--no-cache` only to force a full rebuild in exceptional cases.

### Update Single Service

```bash
# Update only the manager service
./scripts/update-service.sh manager

# Update only the frontend
./scripts/update-service.sh frontend

# Force a full rebuild of a service (rarely needed)
./scripts/update-service.sh manager docker-compose.yml --no-cache
```

### Update All Services

```bash
# Pull latest code for every repository
cd /opt/trackhub
for repo in TrackHub TrackHub.AuthorityServer TrackHubSecurity TrackHub.Manager TrackHubRouter TrackHub.Geofencing TrackHub.Telemetry TrackHub.Reporting TrackHub.Deployment; do
  cd /opt/trackhub/$repo && git pull
done

# Rebuild and deploy (cached, deterministic)
cd /opt/trackhub/TrackHub.Deployment
./scripts/deploy.sh full --build
```

### Zero-Downtime Updates

> **Announce the window first.** Publish a maintenance announcement from the portal
> (**Platform Status → Manage announcements**, SuperAdministrator only) *before* you start.
> Announcements are stored by the Manager service and served by it, so once Manager restarts the
> banner cannot be loaded — a notice scheduled in advance is what users actually see during the
> window. Give it a `Starts at` / `Ends at` covering the window and it retires itself.
>
> Note the same dependency during the update: while Manager is restarting, the banner disappears
> from `/status` and from the portal shell. That is expected degradation, not a fault — the service
> tiles keep working because they are probed directly.

For production environments, update services one at a time:

```bash
# Update backend services
./scripts/update-service.sh authority
./scripts/update-service.sh security
./scripts/update-service.sh manager
./scripts/update-service.sh router
./scripts/update-service.sh geofencing
./scripts/update-service.sh telemetry
./scripts/update-service.sh reporting
./scripts/update-service.sh syncworker

# Update frontend last
./scripts/update-service.sh frontend
./scripts/update-service.sh nginx
```

---

## Monitoring & Maintenance

### View Logs

```bash
# All services
./scripts/logs.sh

# Specific service
./scripts/logs.sh manager

# Last 50 lines, no follow
./scripts/logs.sh security -n 50 --no-follow
```

### Health Checks

```bash
# Check all services
./scripts/health-check.sh your-domain.com

# HTTP endpoints (nginx static probe + one anonymous passthrough per service)
curl -k https://your-domain.com/health
curl -k https://your-domain.com/health/authority
curl -k https://your-domain.com/health/security
curl -k https://your-domain.com/health/manager
curl -k https://your-domain.com/health/router
curl -k https://your-domain.com/health/geofencing
curl -k https://your-domain.com/health/telemetry
curl -k https://your-domain.com/health/reporting
```

Manager, Telemetry, Security, Geofencing and AuthorityServer health checks include a database
probe; Reporting and Router are liveness-only. The SyncWorker has no HTTP listener — its liveness is
derived from the rows it writes, and it is surfaced on the platform status page rather than here.

Non-technical users can check the same signals without a shell — and without signing in — at
`https://your-domain.com/status`.

### Backup Configuration

```bash
# Create backup
./scripts/backup.sh

# Backups are stored in deployment/backups/
```

### Database Backup & Restore

`backup` takes **no database argument** — it dumps *both* databases into a single
timestamped `.tar.gz` under `backups/database/`, and `restore` takes that tarball.

```bash
# Back up BOTH databases into one archive
./scripts/backup-database.sh backup

# List all backups
./scripts/backup-database.sh list

# Restore from a backup archive
./scripts/backup-database.sh restore backups/database/trackhub_backup_20260711_120000.tar.gz

# Cleanup old backups (keep last 7 days)
./scripts/backup-database.sh cleanup 7
```

### Backing Up Uploaded Documents

`backup-database.sh` covers PostgreSQL only. Documents uploaded through the document
management feature live on the **`manager-documents`** Docker volume and are the only
stateful data *outside* the database. Back the volume up separately:

```bash
# Find the volume (its name is prefixed with the compose project name)
docker volume ls | grep manager-documents

# Archive it
docker run --rm -v <volume-name>:/data -v "$PWD/backups:/backup" alpine \
  tar czf /backup/documents-$(date +%F).tar.gz -C /data .
```

### Version Management & Rollback

Both `tag` and `rollback` take a **service name** plus the tag. There is **no `delete`
command**.

```bash
# Tag a service's current image before making changes
./scripts/rollback.sh tag manager v1.0.0

# List tagged versions
./scripts/rollback.sh list

# Show a service's image history
./scripts/rollback.sh history manager

# Roll a service back to a previous tag
./scripts/rollback.sh rollback manager v1.0.0
```

### SSL Certificate Renewal

Let's Encrypt certificates auto-renew via a daily cron job set up by `generate-certs.sh`. The renewal uses the webroot method (no downtime).

```bash
# Check renewal status
./scripts/renew-ssl.sh

# Verify auto-renewal cron
crontab -l | grep renew-ssl
```

### Service Management

```bash
# Stop all services
docker compose down

# Deploy/start all services (cached, deterministic builds + forced recreation)
./scripts/deploy.sh full --build

# Restart specific service
docker compose restart manager

# View service status
docker compose ps
```

### Resource Monitoring

```bash
# Container resource usage
docker stats

# System resources
htop
```

---

## Troubleshooting

### Common Issues

#### Services won't start

```bash
# Check logs
docker compose logs --tail=100

# Check specific service
docker logs trackhub-authority
```

#### A service still runs old code after an update

This should not happen with the current deployment: `.dockerignore` files keep
stale host `bin/`/`obj/`/`node_modules/` out of the build so layer caching detects
real source changes, the frontend refreshes its static assets from the image on
every start, and containers are always force-recreated. If you still suspect
staleness:

```bash
# 1. Confirm the latest code was actually pulled
git -C /opt/trackhub/<repo> log -1 --oneline

# 2. Redeploy (normal cached build already rebuilds changed services)
./scripts/deploy.sh full --build

# 3. Only if you must bypass the cache entirely (rarely needed)
./scripts/deploy.sh full --build --no-cache
```

You should **not** need to delete repositories, remove volumes, or run the deploy
command multiple times.

#### Database connection issues

```bash
# Test connectivity from container
docker exec -it trackhub-authority ping db-server.com

# Check environment variables
docker exec -it trackhub-authority env | grep ConnectionStrings
# (DB_CONNECTION_* exists only on the db-init container; services get ConnectionStrings__*)
```

#### Certificate issues

```bash
# Verify certificate files exist
ls -la certificates/

# Test certificate
openssl x509 -in certificates/fullchain.pem -text -noout
```

#### CORS errors

1. Check `ALLOWED_CORS_ORIGINS` in `.env`
2. Ensure frontend URL matches exactly (including protocol)
3. Check nginx configuration

#### OpenIddict HTTPS error (ID2083)

If you see `error:invalid_request` with `This server only accepts HTTPS requests`:

1. The Authority Server needs `ForwardedHeaders` middleware to trust nginx's `X-Forwarded-Proto` header
2. Ensure `UseForwardedHeaders` is called **before** `UseHttpsRedirection` in `Program.cs`
3. This is required because nginx terminates SSL and forwards HTTP internally

#### NuGet package restore failures in Docker

If `dotnet restore` fails with missing TrackHubCommon packages:

1. Confirm the `common` build stage packed successfully — the build log should show four
   `Successfully created package '/local-nuget/TrackHubCommon.*.nupkg'` lines
2. Verify the packed `<Version>` in `TrackHubCommon/Directory.Build.props` matches the
   `TrackHubCommon.*` `PackageVersion` entries in the service's `Directory.Packages.props`
3. Verify `nuget-packages/nuget.config` exists with the `local` (`/nuget-packages`) source configured
4. All Dockerfiles should use `--configfile /nuget-packages/nuget.config` on restore
5. Ensure stale host-built packages under `TrackHubCommon/NugetPackages/` are not leaking into
   the build context (they are excluded by the `.dockerignore` files)

#### 502 Bad Gateway

1. Check if backend service is running: `docker compose ps`
2. Check service logs: `docker logs trackhub-<service>`
3. Verify network connectivity between containers

### Debug Mode

Enable detailed logging:

```bash
# Add to service environment in docker-compose.yml
environment:
  - ASPNETCORE_ENVIRONMENT=Development
  - Logging__LogLevel__Default=Debug
```

### Reset Deployment

> 🛑 **`-v` is destructive and irreversible.** It deletes the Docker volumes, which means:
> - **`manager-documents`** — *every uploaded document*. This data is **not** in PostgreSQL
>   and **not** covered by `backup-database.sh`. Archive it first (see
>   [Backing Up Uploaded Documents](#backing-up-uploaded-documents)).
> - **`db-init-flag`** — removing it **re-arms the one-time User/Account ID sync**, which
>   rewrites user and account IDs on the next deploy against your existing databases.
>
> For a normal restart use `docker compose down --remove-orphans` (no `-v`).

Only if you genuinely want to discard all local container state:

```bash
# Stop and remove everything INCLUDING volumes (see warning above)
docker compose down -v --remove-orphans

# Remove all images
docker system prune -a

# Re-deploy
./scripts/deploy.sh full --build
```

---

## Security Considerations

> **⚠️ Development secrets are committed on purpose.** The repositories ship with generic
> development credentials (OAuth client secrets in `ClientSeeder/clients.json`, sample
> appsettings, `.env` examples, seeded users) so the multi-service development environment can
> be stood up without manual secret plumbing. **They are for local/dev use only** — every
> production deployment must replace them via environment variables and the steps below
> (regenerate client secrets, strong DB/certificate passwords).

1. **Never commit `.env` files** to version control
2. **Use strong passwords** for database and certificates
3. **Rotate the seeded OAuth client secrets** (`syncworker_client`, `router_client`,
   `security_client`, `geofence_client`) before
   exposing any environment beyond local development
4. **Keep Docker and OS updated** with security patches
5. **Use Let's Encrypt** for production SSL certificates
6. **Configure firewall** to only allow necessary ports
7. **Regular backups** of configuration and database
8. **Monitor logs** for suspicious activity

---

## Support

For issues and questions:
- GitHub Issues: [TrackHub Repository](https://github.com/shernandezp/TrackHub/issues)
- Documentation: [Project README](https://github.com/shernandezp/TrackHub)

---

## License

Apache License 2.0 - See individual repository LICENSE files for details.
