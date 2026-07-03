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
12. [Updating Services](#updating-services)
13. [Monitoring & Maintenance](#monitoring--maintenance)
14. [Troubleshooting](#troubleshooting)

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
| **TrackHub.Reporting** | Reports generation | .NET 10, REST API |

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
│  │     /Router        /Geofence    /Reporting                 │  │
│  │     Router         Geofencing   Reporting                  │  │
│  │     (:8080)        (:8080)      (:8080)                    │  │
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

> **Note:** .NET SDK is only required if building services outside Docker. Docker builds include the SDK automatically.

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
git clone https://github.com/shernandezp/TrackHub.Reporting.git
```

### 3. Configure Environment

```bash
cd TrackHub.Deployment

# Copy example configuration
cp .env.example .env

# Edit configuration (see Configuration Reference section)
nano .env
```

### 4. Set Up Certificates

```bash
# Obtain Let's Encrypt SSL certificate + generate OpenIddict certificate
# Requires DOMAIN and LETSENCRYPT_EMAIL in .env (or pass as arguments)
sudo ./scripts/generate-certs.sh your-domain.com admin@your-domain.com
```

### 5. Configure OAuth Clients

```bash
# Copy and edit clients.json
cp config/clients.json.example config/clients.json
nano config/clients.json

# Update the callback URI with your domain
```

### 6. Deploy

```bash
# Make scripts executable
chmod +x scripts/*.sh

# Deploy full stack
./scripts/deploy.sh full --build
```

### 7. Verify Deployment

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

# Database
DB_CONNECTION_SECURITY=server=db.example.com;user id=postgres;password=SecurePass123;database=TrackHubSecurity;port=5432
DB_CONNECTION_MANAGER=server=db.example.com;user id=postgres;password=SecurePass123;database=TrackHub;port=5432
DB_CONNECTION_LOGGING=server=db.example.com;user id=postgres;password=SecurePass123;database=TrackHub;port=5432

# Certificate
CERTIFICATE_PASSWORD=your-cert-password

# Encryption (generate a new GUID)
ENCRYPTION_KEY=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx

# Update all REACT_APP_ URLs with your domain
REACT_APP_AUTHORIZATION_ENDPOINT=https://trackhub.example.com/Identity/authorize
# ... etc
```

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
    {"name": "web_scope", "resource": "web_resource"},
    {"name": "mobile_scope", "resource": "mobile_resource"},
    {"name": "sec_scope", "resource": "sec_resource"}
  ],
  "PKCEClients": [
    {
      "clientId": "web_client",
      "uri": "https://trackhub.example.com/authentication/callback",
      "scope": "web_scope"
    }
  ],
  "serviceClients": [
    {
      "clientId": "syncworker_client",
      "clientSecret": "generate-a-secure-secret-here"
    }
  ]
}
```

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

1. Gets the user ID from `TrackHubSecurity.security.user`
2. Updates `TrackHub.app.user.userid` with the security user ID
3. Updates `TrackHub.app.user_settings.userid` with the security user ID
4. Gets the account ID from `TrackHub.app.account`
5. Updates `TrackHubSecurity.security.user.accountid` with the account ID

**Manual sync (if needed):**

If you prefer to sync manually via SQL:

```bash
# Connect to PostgreSQL
psql -h db.example.com -U postgres

-- Get user ID from security database
SELECT id FROM "TrackHubSecurity".security."user";
-- Example result: 550e8400-e29b-41d4-a716-446655440000

-- Get current user ID from manager database  
SELECT userid FROM "TrackHub".app."user";
-- Example result: 11111111-1111-1111-1111-111111111111

-- Update user ID in manager database
UPDATE "TrackHub".app."user" 
SET userid = '550e8400-e29b-41d4-a716-446655440000' 
WHERE userid = '11111111-1111-1111-1111-111111111111';

UPDATE "TrackHub".app.user_settings 
SET userid = '550e8400-e29b-41d4-a716-446655440000' 
WHERE userid = '11111111-1111-1111-1111-111111111111';

-- Get account ID from manager database
SELECT accountid FROM "TrackHub".app.account;
-- Example result: 660e8400-e29b-41d4-a716-446655440000

-- Update account ID in security database
UPDATE "TrackHubSecurity".security."user" 
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
| `${DB_CONNECTION_SECURITY}` | Authority, Security | Security database |
| `${DB_CONNECTION_MANAGER}` | Manager, Geofencing | Manager database |
| `${DB_CONNECTION_LOGGING}` | All backend services | Centralized logging database |
| `${CERTIFICATE_PATH}` | All services | Path to OpenIddict certificate |
| `${CERTIFICATE_PASSWORD}` | All services | Certificate password |
| `${ENCRYPTION_KEY}` | Security, Manager, Router | Database encryption key |
| `${GRAPHQL_*_SERVICE}` | Various | Internal service URLs |

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
| `DB_CONNECTION_LOGGING` | Centralized logging DB connection | `server=...;database=TrackHub;...` |
| `CERTIFICATE_PASSWORD` | OpenIddict cert password | `your-password` |
| `ENCRYPTION_KEY` | Database encryption key | `GUID format` |
| `AUTHORITY_URL` | Identity provider URL | `https://domain.com/Identity` |
| `SYNCWORKER_CLIENT_ID` | SyncWorker OAuth client ID | `sync_worker_client` |
| `SYNCWORKER_CLIENT_SECRET` | SyncWorker OAuth client secret | `your-secret` |

### Service Ports (Internal)

| Service | Internal Port |
|---------|---------------|
| Authority | 8080 |
| Security | 8080 |
| Manager | 8080 |
| Router | 8080 |
| Geofencing | 8080 |
| Reporting | 8080 |
| SyncWorker | - (background) |

### URL Paths

| Path | Service |
|------|---------|
| `/` | Frontend (React) |
| `/Identity/*` | Authority Server |
| `/Security/*` | Security API |
| `/Manager/*` | Manager API |
| `/Router/*` | Router API |
| `/Geofence/*` | Geofencing API |
| `/Reporting/*` | Reporting API |

---

## Build Architecture

### Docker Build Context

All services use the parent directory (`/opt/trackhub/`) as the Docker build context. This allows each Dockerfile to access:

1. **Its own source repository** (e.g., `TrackHub.Manager/`)
2. **Local NuGet packages** (`TrackHub.Deployment/nuget-packages/`)
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

### Local NuGet Packages

TrackHub services depend on the **TrackHubCommon** shared library, distributed as local NuGet packages (not published to nuget.org). These packages are stored in `nuget-packages/` and mounted into Docker builds via a `nuget.config` that configures both the local source and nuget.org.

If you update TrackHubCommon, rebuild the packages and copy the new `.nupkg` files to `nuget-packages/` before rebuilding services.

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
- Must be installed and operational before deploying TrackHub

### Manual Database Creation

If not using the automated initialization:

```sql
-- Create databases
CREATE DATABASE "TrackHubSecurity";
CREATE DATABASE "TrackHub";

-- Create user (if needed)
CREATE USER trackhub WITH PASSWORD 'secure_password';
GRANT ALL PRIVILEGES ON DATABASE "TrackHubSecurity" TO trackhub;
GRANT ALL PRIVILEGES ON DATABASE "TrackHub" TO trackhub;
```

### Running Initializers Manually

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

The `db-init` container performs the following on first run:

1. **ClientSeeder** - Inserts OAuth clients into the database
2. **Security DBInitializer** - Creates/migrates security database schema
3. **Manager DBInitializer** - Creates/migrates manager database schema
4. **Sync User/Account IDs** - Updates foreign keys between databases

For migrations with existing data, you should **skip the db-init** to avoid potential conflicts with existing OAuth clients.

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
docker compose up -d --force-recreate --no-build --no-deps nginx frontend authority security manager router geofencing reporting syncworker
```

### Option 3: Pre-create the Initialization Flag

If you want to use the normal deployment process but skip initialization:

```bash
# Create the flag volume and file manually
docker volume create deployment_db-init-flag
docker run --rm -v deployment_db-init-flag:/flags alpine touch /flags/db-initialized

# Now deploy normally - db-init will detect the flag and skip
./scripts/deploy.sh full --build
```

### Option 4: Comment Out db-init in docker-compose.yml

Edit `docker-compose.yml` and comment out the db-init service:

```yaml
# db-init:
#   build:
#     context: .
#     dockerfile: docker/Dockerfile.db-init
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

```bash
# Using the provided script
./scripts/generate-certs.sh your-domain.com 365 your-certificate-password

# Or manually with OpenSSL
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

## Updating Services

Updates are deterministic. `deploy.sh` and `update-service.sh` rebuild images
with the Docker layer cache (source changes are detected automatically) and
always force-recreate containers, and the frontend refreshes its static assets on
every start. You do **not** need `--no-cache`, repeated executions, or manual
volume/repo cleanup. Pass `--no-cache` only to force a full rebuild in
exceptional cases.

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
for repo in TrackHub TrackHub.AuthorityServer TrackHubSecurity TrackHub.Manager TrackHubRouter TrackHub.Geofencing TrackHub.Reporting TrackHub.Deployment; do
  cd /opt/trackhub/$repo && git pull
done

# Rebuild and deploy (cached, deterministic)
cd /opt/trackhub/TrackHub.Deployment
./scripts/deploy.sh full --build
```

### Zero-Downtime Updates

For production environments, update services one at a time:

```bash
# Update backend services
./scripts/update-service.sh authority
./scripts/update-service.sh security
./scripts/update-service.sh manager
./scripts/update-service.sh router
./scripts/update-service.sh geofencing
./scripts/update-service.sh reporting

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

# HTTP endpoints
curl -k https://your-domain.com/health
curl -k https://your-domain.com/health/authority
curl -k https://your-domain.com/health/security
```

### Backup Configuration

```bash
# Create backup
./scripts/backup.sh

# Backups are stored in deployment/backups/
```

### Database Backup & Restore

```bash
# Backup security database
./scripts/backup-database.sh backup security

# Backup manager database  
./scripts/backup-database.sh backup manager

# List all backups
./scripts/backup-database.sh list

# Restore from backup
./scripts/backup-database.sh restore security backups/db/security_20241201_120000.sql

# Cleanup old backups (keep last 7 days)
./scripts/backup-database.sh cleanup 7
```

### Version Management & Rollback

```bash
# Tag current version before making changes
./scripts/rollback.sh tag v1.0.0

# List all tagged versions
./scripts/rollback.sh list

# Rollback to a previous version
./scripts/rollback.sh rollback v1.0.0

# Delete a version tag
./scripts/rollback.sh delete v1.0.0
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
docker exec -it trackhub-authority env | grep DB_
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

1. Ensure `nuget-packages/` directory contains all `.nupkg` files
2. Verify `nuget-packages/nuget.config` exists with local source configured
3. All Dockerfiles should use `--configfile /nuget-packages/nuget.config` on restore

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

```bash
# Stop and remove everything
docker compose down -v --remove-orphans

# Remove all images
docker system prune -a

# Re-deploy
./scripts/deploy.sh full --build
```

---

## Security Considerations

1. **Never commit `.env` files** to version control
2. **Use strong passwords** for database and certificates
3. **Keep Docker and OS updated** with security patches
4. **Use Let's Encrypt** for production SSL certificates
5. **Configure firewall** to only allow necessary ports
6. **Regular backups** of configuration and database
7. **Monitor logs** for suspicious activity

---

## Support

For issues and questions:
- GitHub Issues: [TrackHub Repository](https://github.com/shernandezp/TrackHub/issues)
- Documentation: [Project README](https://github.com/shernandezp/TrackHub)

---

## License

Apache License 2.0 - See individual repository LICENSE files for details.
