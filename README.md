# TrackHub Deployment

Docker-based deployment solution for TrackHub application stack.

## Key Features

- **Complete Stack Orchestration**: Deploy frontend, backend, and all microservices with a single command
- **Flexible Deployment Options**: Full stack, frontend-only, or backend-only configurations
- **Automated SSL Management**: Certificate generation and Let's Encrypt auto-renewal support
- **Centralized Configuration**: Template-based configuration management for all services
- **Centralized Database Logging**: Shared PostgreSQL log sink configuration for APIs and background services
- **Database Backup & Restore**: Automated backup scripts with versioned restore capabilities
- **Health Monitoring**: Built-in health checks for all services, plus a **public status page** at
  `/status` that works without signing in — and platform-wide maintenance announcements
  publishable by a SuperAdministrator
- **Version Management**: Tag, list, and rollback deployments with ease
- **Nginx Reverse Proxy**: Pre-configured routing for all microservices
- **Document Storage**: Local volume by default, or S3 / Azure Blob for the Manager's
  document management feature

---

## Quick Links

- [Quick Start Guide](QUICKSTART.md) - Simplified guide for beginners
- [Full Installation Guide](INSTALL.md) - Comprehensive step-by-step instructions
- [Configuration Reference](INSTALL.md#configuration-reference) - All environment variables
- [Troubleshooting](INSTALL.md#troubleshooting) - Common issues and solutions

## Project Structure

```
TrackHub.Deployment/
├── docker-compose.yml           # Full stack deployment
├── docker-compose.frontend.yml  # Frontend-only deployment
├── docker-compose.backend.yml   # Backend-only deployment
├── .env.example                 # Environment template (full stack)
├── .env.frontend.example        # Environment template (frontend)
├── .env.backend.example         # Environment template (backend)
├── INSTALL.md                   # Detailed installation guide
├── QUICKSTART.md                # Simplified guide for beginners
├── README.md                    # This file
├── certificates/                # SSL and OpenIddict certificates
├── config/
│   ├── clients.json.example     # OAuth clients configuration
│   └── appsettings.template.json # Master config template
├── docker/
│   ├── Dockerfile.frontend      # React frontend
│   ├── Dockerfile.authority     # Authority Server
│   ├── Dockerfile.security      # Security API
│   ├── Dockerfile.manager       # Manager API
│   ├── Dockerfile.router        # Router API
│   ├── Dockerfile.geofencing    # Geofencing API
│   ├── Dockerfile.reporting     # Reporting API
│   ├── Dockerfile.telemetry     # Telemetry API
│   ├── Dockerfile.syncworker    # SyncWorker background service
│   ├── Dockerfile.db-init       # Database initialization
│   ├── Dockerfile.*.dockerignore # Per-Dockerfile ignore files (exclude bin/obj/node_modules)
│   └── frontend-entrypoint.sh   # Refreshes frontend assets in the shared volume on start
├── nginx/
│   ├── nginx.conf               # Full stack nginx config
│   ├── nginx.frontend.conf      # Frontend-only nginx config
│   └── nginx.backend.conf       # Backend-only nginx config
├── nuget-packages/              # NuGet feed config for TrackHubCommon
│   └── nuget.config             # NuGet source configuration (packages packed in-container)
└── scripts/
    ├── deploy.sh                # Main deployment script
    ├── update-service.sh        # Update individual services
    ├── health-check.sh          # Health check script
    ├── logs.sh                  # Log viewer
    ├── backup.sh                # Configuration backup
    ├── backup-database.sh       # PostgreSQL backup/restore
    ├── rollback.sh              # Version rollback utility
    ├── generate-certs.sh        # Certificate generation
    ├── renew-ssl.sh             # SSL auto-renewal (Let's Encrypt)
    ├── generate-appsettings.sh  # Generate appsettings.json files
    ├── sync-config.sh           # Sync all configuration
    ├── sync-user-account-ids.sh # Sync User/Account IDs between DBs
    └── init-databases.sh        # Database initialization
```

## Quick Start

```bash
# 1. Configure environment
cp .env.example .env
nano .env

# 2. Configure OAuth clients
cp config/clients.json.example config/clients.json
nano config/clients.json

# 3. Create the database schema — REQUIRED. db-init only SEEDS data; it does not
#    create tables. See QUICKSTART.md Step 5 for the three `dotnet ef database update`
#    commands (Security, Manager, Geofencing). Skipping this makes db-init fail.

# 4. Generate certificates
sudo ./scripts/generate-certs.sh your-domain.com admin@your-domain.com

# 5. Deploy
./scripts/deploy.sh full --build

# 6. Check health
./scripts/health-check.sh your-domain.com
```

New installs should follow [QUICKSTART.md](QUICKSTART.md) end to end — it covers the
databases, PostGIS, migrations and OAuth clients in order.

## Deployment Options

| Command | Description |
|---------|-------------|
| `./scripts/deploy.sh full` | Deploy frontend + all backend services (default) |
| `./scripts/deploy.sh frontend` | Deploy frontend only |
| `./scripts/deploy.sh backend` | Deploy backend services only |

Builds use the Docker layer cache and reliably detect source changes, so updated
code is always deployed without needing `--no-cache` or repeated runs. Containers
are always started with `--force-recreate` so the freshly built images take
effect, and the frontend refreshes its static assets on every start. Pass
`--no-cache` only if you ever need to force a full rebuild:

```bash
./scripts/deploy.sh full --build            # normal, cached, deterministic
./scripts/deploy.sh full --build --no-cache # optional full rebuild
```

See [INSTALL.md → Updating Services](INSTALL.md#updating-services) for the
authoritative update procedure and how deterministic rebuilds work.

## Service Management

```bash
# Update a single service
./scripts/update-service.sh manager

# View logs
./scripts/logs.sh
./scripts/logs.sh manager -n 50

# Health check
./scripts/health-check.sh your-domain.com

# Backup configuration
./scripts/backup.sh

# Database backup and restore (takes NO database argument — dumps both into one archive)
./scripts/backup-database.sh backup                                    # Back up both DBs
./scripts/backup-database.sh list                                      # List backups
./scripts/backup-database.sh restore backups/database/<file>.tar.gz    # Restore
./scripts/backup-database.sh cleanup 7                                 # Prune old backups

# Version management and rollback (both take a SERVICE name)
./scripts/rollback.sh tag manager v1.0.0        # Tag a service's current image
./scripts/rollback.sh list                      # List versions
./scripts/rollback.sh history manager           # Show a service's image history
./scripts/rollback.sh rollback manager v1.0.0   # Roll a service back
```

> **Uploaded documents are not in PostgreSQL.** They live on the `manager-documents`
> volume and are not covered by `backup-database.sh` — back that volume up separately
> (see [INSTALL.md](INSTALL.md#backing-up-uploaded-documents)), and never run
> `docker compose down -v`, which deletes them.

## Configuration Management

All backend services share similar `appsettings.json` configurations, generated from the
central `.env` into `generated/` and bind-mounted read-only over each container's
`/app/appsettings.json` by the compose files. `deploy.sh` regenerates them from `.env`
before every backend/full deploy; environment variables set in compose still take precedence
over the mounted file. Use the centralized configuration tools to work with them directly:

```bash
# Preview appsettings.json for all services (stdout)
./scripts/generate-appsettings.sh

# Generate all backend configs into generated/
./scripts/generate-appsettings.sh --output-dir ./generated

# Generate for a specific service
./scripts/generate-appsettings.sh --service manager --output-dir ./generated

# Generate all backend configs (same as generate-appsettings.sh --output-dir generated)
./scripts/sync-config.sh generate

# Validate configuration
./scripts/sync-config.sh validate

# Show current configuration
./scripts/sync-config.sh show
```

## Architecture

### Services

| Service | Path | Port | Description |
|---------|------|------|-------------|
| Frontend | `/` | - | React.js web application (incl. the anonymous `/status` page) |
| Authority | `/Identity/` | 8080 | OpenIddict identity server |
| Security | `/Security/` | 8080 | User & permissions (GraphQL) |
| Manager | `/Manager/` | 8080 | Asset management (GraphQL) + one **anonymous** REST endpoint: `api/PlatformStatus/announcements` |
| Router | `/Router/` | 8080 | Device routing (GraphQL) |
| Geofencing | `/Geofence/` | 8080 | Geofence management (GraphQL) |
| Reporting | `/Reporting/` | 8080 | Reports generation (REST) |
| Telemetry | `/Telemetry/` | 8080 | Position & telemetry store (GraphQL) |
| SyncWorker | - | - | Background data sync service (built from `TrackHubRouter`) |
| nginx | - | 80/443 | Reverse proxy, SSL termination |
| db-init | - | - | One-shot **seeder** (data only — never schema) |

**Document management** (part of Manager) stores uploaded files on the `manager-documents`
volume by default, or in S3 / Azure Blob. Uploads are capped at **50 MB** by nginx. This
volume is the only stateful data outside PostgreSQL — back it up separately.

### Technology Stack

- **Frontend**: React.js 19, Material-UI
- **Backend**: .NET 10, Hot Chocolate (GraphQL)
- **Auth**: OpenIddict
- **Database**: PostgreSQL
- **Proxy**: Nginx
- **Container**: Docker

## Requirements

- Docker 24.0+
- Docker Compose v2.20+
- PostgreSQL 14+ (external, with PostGIS)
- SSL Certificate
- Domain name

## Database Migrations

TrackHub uses EF Core migrations as the source of truth for schema ("DB updates").
The `db-init` container **seeds data only** — it does not create or migrate the schema —
so migrations must be applied (new installations **and** updates) with your EF migration
process, e.g. `dotnet ef database update`, for every stateful service.

> The migration host needs the .NET SDK and `dotnet-ef`. The `TrackHubCommon.*` packages are
> not on nuget.org, so pack them from the
> `TrackHubCommon/` source into a local feed and register it before running `dotnet ef`
> (Docker image builds pack them automatically in a `common` stage).
> Full commands: [QUICKSTART.md Step 5](QUICKSTART.md) / [INSTALL.md → Applying Migrations](INSTALL.md#applying-migrations).

| Service | Database | Schema |
|---------|----------|--------|
| TrackHubSecurity | `TrackHubSecurity` | `security` (+ OpenIddict) |
| TrackHub.Manager | `TrackHub` | `app`, `map`, and `telemetry` (Manager owns the telemetry tables) |
| TrackHub.Geofencing | `TrackHub` | `geofencing` (PostGIS) |

> Telemetry has **no migrations of its own** — its `telemetry`-schema tables are created by
> the Manager migrations, so `DB_CONNECTION_TELEMETRY` must point at the same `TrackHub`
> database. PostgreSQL must have **PostGIS** enabled for the Geofencing schema.

Apply migrations **before** deploying the updated services (`db-init` seeds data only and
assumes the schema already exists). See [INSTALL.md → Upgrading From a Previous Version](INSTALL.md#upgrading-from-a-previous-version).

Centralized logging requires a `TrackHub` database and the `DB_CONNECTION_LOGGING` environment variable. The Serilog sink auto-creates the `logs` table on first write.

## Support

See [INSTALL.md](INSTALL.md) for detailed documentation.

For issues: [GitHub Issues](https://github.com/shernandezp/TrackHub/issues)

## License

Apache License 2.0
