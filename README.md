# TrackHub Deployment

Docker-based deployment solution for TrackHub application stack.

## Key Features

- **Complete Stack Orchestration**: Deploy frontend, backend, and all microservices with a single command
- **Flexible Deployment Options**: Full stack, frontend-only, or backend-only configurations
- **Automated SSL Management**: Certificate generation and Let's Encrypt auto-renewal support
- **Centralized Configuration**: Template-based configuration management for all services
- **Centralized Database Logging**: Shared PostgreSQL log sink configuration for APIs and background services
- **Database Backup & Restore**: Automated backup scripts with versioned restore capabilities
- **Health Monitoring**: Built-in health checks for all services
- **Version Management**: Tag, list, and rollback deployments with ease
- **Nginx Reverse Proxy**: Pre-configured routing for all microservices

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
├── database-structural.sql      # Structural domain migration script
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
│   ├── Dockerfile.syncworker    # SyncWorker background service
│   ├── Dockerfile.db-init       # Database initialization
│   ├── Dockerfile.*.dockerignore # Per-Dockerfile ignore files (exclude bin/obj/node_modules)
│   └── frontend-entrypoint.sh   # Refreshes frontend assets in the shared volume on start
├── nginx/
│   ├── nginx.conf               # Full stack nginx config
│   ├── nginx.frontend.conf      # Frontend-only nginx config
│   └── nginx.backend.conf       # Backend-only nginx config
├── nuget-packages/              # Local NuGet packages (TrackHubCommon)
│   ├── nuget.config             # NuGet source configuration
│   └── *.nupkg                  # Shared library packages
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

# 3. Generate certificates
chmod +x scripts/*.sh
./scripts/generate-certs.sh your-domain.com admin@your-domain.com

# 4. Deploy
./scripts/deploy.sh full --build

# 5. Check health
./scripts/health-check.sh your-domain.com
```

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

# Database backup and restore
./scripts/backup-database.sh backup security    # Backup security DB
./scripts/backup-database.sh backup manager     # Backup manager DB
./scripts/backup-database.sh list               # List backups
./scripts/backup-database.sh restore security backup.sql  # Restore

# Version management and rollback
./scripts/rollback.sh tag v1.0.0               # Tag current version
./scripts/rollback.sh list                     # List versions
./scripts/rollback.sh rollback v1.0.0          # Rollback to version
```

## Configuration Management

All services share similar `appsettings.json` configurations. Use the centralized configuration tools to update them all at once:

```bash
# Generate appsettings.json for all services (preview)
./scripts/generate-appsettings.sh

# Generate to output directory
./scripts/generate-appsettings.sh --output-dir ./generated

# Deploy directly to source repositories
./scripts/generate-appsettings.sh --deploy-to-sources

# Generate for a specific service
./scripts/generate-appsettings.sh --service manager

# Full config sync (backend + frontend)
./scripts/sync-config.sh deploy

# Validate configuration
./scripts/sync-config.sh validate

# Show current configuration
./scripts/sync-config.sh show
```

## Architecture

### Services

| Service | Path | Port | Description |
|---------|------|------|-------------|
| Frontend | `/` | - | React.js web application |
| Authority | `/Identity/` | 8080 | OpenIddict identity server |
| Security | `/Security/` | 8080 | User & permissions (GraphQL) |
| Manager | `/Manager/` | 8080 | Asset management (GraphQL) |
| Router | `/Router/` | 8080 | Device routing (GraphQL) |
| Geofencing | `/Geofence/` | 8080 | Geofence management (GraphQL) |
| Reporting | `/Reporting/` | 8080 | Reports generation (REST) |
| SyncWorker | - | - | Background data sync service |

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

Before deploying updated services, run the required migration scripts against your PostgreSQL database:

```bash
# Structural domain migration (adds AccountId to transporters and devices tables)
psql -h your-db-host -U postgres -d trackhub_manager -f database-structural.sql
```

Migration scripts are idempotent and safe to re-run. Always run migrations **before** deploying the updated application services.

Centralized logging requires a `TrackHub` database and the `DB_CONNECTION_LOGGING` environment variable. The Serilog sink auto-creates the `logs` table on first write.

## Support

See [INSTALL.md](INSTALL.md) for detailed documentation.

For issues: [GitHub Issues](https://github.com/shernandezp/TrackHub/issues)

## License

Apache License 2.0
