# TrackHub Quick Start Guide

A simplified guide for first-time TrackHub installation. For advanced options, see [INSTALL.md](INSTALL.md).

---

## What You Need Before Starting

| Requirement | Details |
|-------------|---------|
| **Server** | Ubuntu 24.04.4 LTS, 4+ CPU cores, 8 GB RAM, 50 GB SSD |
| **Database** | PostgreSQL 14+ already installed (local or remote) |
| **Domain** | A registered domain name pointing to your server |
| **Ports** | 80 (HTTP) and 443 (HTTPS) open |

---

## Step 1: Install Docker

```bash
curl -fsSL https://get.docker.com -o get-docker.sh
sudo sh get-docker.sh
sudo usermod -aG docker $USER
```

Log out and log back in, then verify:

```bash
docker --version
docker compose version
```

---

## Step 2: Clone Repositories

```bash
sudo mkdir -p /opt/trackhub && sudo chown $USER:$USER /opt/trackhub
cd /opt/trackhub

git clone https://github.com/shernandezp/TrackHub.Deployment.git

cd TrackHub.Deployment
cp .env.example .env
./scripts/clone-repos.sh
cd ..
```

> Deploying from private repositories? Set `GITHUB_OWNER`, `GITHUB_REPO_SUFFIX`,
> `GITHUB_USER` and `GITHUB_PASSWORD` in `.env` before running `clone-repos.sh`.
> `GITHUB_PASSWORD` must be a Personal Access Token — GitHub does not accept account
> passwords over HTTPS. See [INSTALL.md](INSTALL.md) for the full table.

> The **SyncWorker** background service is built from the `TrackHubRouter` repo — there is
> nothing extra to clone for it.

---

## Step 3: Prepare the Database

Connect to PostgreSQL **as a superuser** and create the two databases. The `postgis`
extension is required by Geofencing and must be created by a superuser — a plain owner
role cannot run `CREATE EXTENSION`.

```sql
CREATE DATABASE "TrackHubSecurity";
CREATE DATABASE "TrackHub";

-- Create a user (adjust password)
CREATE USER trackhub WITH PASSWORD 'YourStrongPassword';
GRANT ALL PRIVILEGES ON DATABASE "TrackHubSecurity" TO trackhub;
GRANT ALL PRIVILEGES ON DATABASE "TrackHub" TO trackhub;
```

On **PostgreSQL 15+**, `GRANT ... ON DATABASE` is *not* enough to create objects — the role
also needs rights on the `public` schema. Serilog auto-creates its `logs` table there, so
without this, logging fails at first write. Run in **both** databases:

```sql
\c TrackHubSecurity
GRANT ALL ON SCHEMA public TO trackhub;

\c TrackHub
GRANT ALL ON SCHEMA public TO trackhub;
```

Then, connected **to the `TrackHub` database** (still as superuser):

```sql
\c TrackHub
CREATE EXTENSION IF NOT EXISTS postgis;
```

Both databases are still **empty** at this point — the schema is created in Step 5.

---

## Step 4: Configure Environment

```bash
cd /opt/trackhub/TrackHub.Deployment
cp .env.example .env
nano .env
```

**Required values to set:**

| Variable | What to Enter |
|----------|---------------|
| `DOMAIN` | Your domain name (e.g., `trackhub.example.com`) |
| `ALLOWED_CORS_ORIGINS` | `https://trackhub.example.com` |
| `DB_CONNECTION_SECURITY` | `server=DB_HOST;port=5432;database=TrackHubSecurity;user id=trackhub;password=YourStrongPassword` |
| `DB_CONNECTION_MANAGER` | `server=DB_HOST;port=5432;database=TrackHub;user id=trackhub;password=YourStrongPassword` |
| `DB_CONNECTION_TELEMETRY` | Same `TrackHub` database as above (Telemetry lives in the `telemetry` schema) |
| `DB_CONNECTION_LOGGING` | `server=DB_HOST;port=5432;database=TrackHub;user id=trackhub;password=YourStrongPassword` |
| `CERTIFICATE_PASSWORD` | A strong password for the token-signing certificate |
| `ENCRYPTION_KEY` | A GUID (generate with `uuidgen` or any GUID tool) |
| `AUTHORITY_URL` | `https://trackhub.example.com/Identity` |
| `SYNCWORKER_CLIENT_SECRET` / `ROUTER_CLIENT_SECRET` / `SECURITY_CLIENT_SECRET` / `GEOFENCE_CLIENT_SECRET` | Service-to-service secrets — must match `config/clients.json` (Step 6) |

Replace `DB_HOST` with your PostgreSQL server address (`localhost` if on the same server).

> ⚠️ Write the user field as **`user id=`** — *with a space*. The deployment scripts
> (`init-databases.sh`, `backup-database.sh`, `sync-user-account-ids.sh`) parse the
> connection string on that exact key. Writing `userid=` makes the user parse as empty
> and **`db-init` fails on first deploy**.

All `REACT_APP_*` URLs in `.env.example` point at `your-domain.com` — replace the domain in
every one of them. The `DOCUMENT_STORAGE_*` keys can stay at their defaults (documents are
stored on the `manager-documents` volume); only change them if you use S3 or Azure Blob,
which require additional keys — see [INSTALL.md](INSTALL.md#configuration-reference).

---

## Step 5: Create the Database Schema (EF migrations)

> ⚠️ **Do not skip this.** `db-init` (which runs during deploy) **only seeds data** — it does
> **not** create or alter tables. If you deploy against the empty databases from Step 3, the
> `db-init` container fails and the stack never comes up.

Three services own migrations. Telemetry has none of its own — its `telemetry` schema is
created by the Manager migrations.

Requires the .NET SDK and `dotnet-ef` on the machine that can reach PostgreSQL:

```bash
dotnet tool install --global dotnet-ef
```

**Pack TrackHubCommon into a local feed first.** The services depend on `TrackHubCommon.*`
packages that are **not on nuget.org** — pack
them from source, then register the feed. Without this, `dotnet ef` fails to restore
(Docker image builds pack them automatically in a `common` stage):

```bash
cd /opt/trackhub
# `dotnet build` (not `dotnet pack`) — GeneratePackageOnBuild emits the .nupkg files
dotnet build TrackHubCommon/src/Common.Web/Common.Web.csproj -c Release
mkdir -p /opt/trackhub/local-nuget
find TrackHubCommon/src -name 'TrackHubCommon.*.nupkg' -exec cp {} /opt/trackhub/local-nuget/ \;
dotnet nuget add source /opt/trackhub/local-nuget -n trackhub-local
```

Now apply the migrations:

```bash
cd /opt/trackhub

# Security → TrackHubSecurity database
ConnectionStrings__Security="server=DB_HOST;port=5432;database=TrackHubSecurity;user id=trackhub;password=YourStrongPassword" \
dotnet ef database update \
  --project TrackHubSecurity/src/Infrastructure/SecurityDB \
  --startup-project TrackHubSecurity/src/Web

# Manager → TrackHub database (also creates the telemetry schema)
ConnectionStrings__DefaultConnection="server=DB_HOST;port=5432;database=TrackHub;user id=trackhub;password=YourStrongPassword" \
dotnet ef database update \
  --project TrackHub.Manager/src/Infrastructure/ManagerDB \
  --startup-project TrackHub.Manager/src/Web

# Geofencing → TrackHub database (requires the postgis extension from Step 3)
ConnectionStrings__DefaultConnection="server=DB_HOST;port=5432;database=TrackHub;user id=trackhub;password=YourStrongPassword" \
dotnet ef database update \
  --project TrackHub.Geofencing/src/Infrastructure/ManagerDB \
  --startup-project TrackHub.Geofencing/src/Web
```

Re-run these same three commands on **every upgrade that adds migrations**.

---

## Step 6: Generate Certificates

**Add `LETSENCRYPT_EMAIL` to your `.env` file:**

```env
LETSENCRYPT_EMAIL=admin@your-domain.com
```

**Obtain Let's Encrypt SSL + generate OpenIddict certificate:**

```bash
sudo ./scripts/generate-certs.sh your-domain.com admin@your-domain.com YourCertificatePassword
```

This will:
- Obtain a free SSL certificate from Let's Encrypt (auto-renews every 90 days)
- Generate the OpenIddict token-signing certificate (`certificate.pfx`)
- Set up a daily cron job for automatic renewal

---

## Step 7: Configure OAuth Clients

```bash
cp config/clients.json.example config/clients.json
nano config/clients.json
```

Update the `web_client` callback URIs to use your domain (the frontend expects the
`/authentication/callback` path), and set each service client's secret to match the
`*_CLIENT_SECRET` values in your `.env`:

```
https://your-domain.com/authentication/callback
```

---

## Step 8: Deploy

```bash
./scripts/deploy.sh full --build
```

This builds all containers and force recreates the running containers from the
freshly built images. First run takes several minutes.

---

## Step 9: Verify

```bash
# Check all containers are running
docker compose ps

# Check service health
./scripts/health-check.sh your-domain.com
```

Open `https://your-domain.com` in your browser. You should see the TrackHub login page.

Then open `https://your-domain.com/status` — the platform status page. It loads **without signing
in** and shows a tile per service, so it is the fastest single-URL confirmation that the whole stack
is reachable. Every tile should read *Working*; a grey *Unknown* tile usually means that service's
`REACT_APP_*` endpoint is missing from `.env`.

---

## Updating TrackHub

> ⚠️ **Upgrading an instance installed before the Telemetry / SyncWorker / Documents release?**
> The `git pull` + redeploy below is **not enough**. That release adds a new repository
> (`TrackHub.Telemetry`), new `.env` keys, new OAuth service clients, and new database
> migrations — none of which a plain redeploy creates for you. Follow
> [INSTALL.md → Upgrading From a Previous Version](INSTALL.md#upgrading-from-a-previous-version)
> **once** (back up → clone Telemetry → reconcile `.env` → reconcile `clients.json` →
> apply migrations → `deploy.sh full --build`). After that one-time upgrade, the steps
> below are all you need.

For code-only updates, updates are deterministic: `deploy.sh` rebuilds only what changed
(source changes are detected automatically) and always force-recreates containers, and the
frontend refreshes its static assets on every start. You do **not** need `--no-cache`,
repeated runs, or manual volume cleanup.

### Update Everything

```bash
cd /opt/trackhub

# Pull latest code for all repos
for repo in TrackHub TrackHub.AuthorityServer TrackHubSecurity TrackHub.Manager TrackHubRouter TrackHub.Geofencing TrackHub.Telemetry TrackHub.Reporting TrackHubCommon TrackHub.Deployment; do
  cd /opt/trackhub/$repo && git pull
done

# Rebuild and deploy (cached, deterministic)
cd /opt/trackhub/TrackHub.Deployment
./scripts/deploy.sh full --build
```

> If the release adds EF migrations, apply them (Step 5 commands) **before** deploying —
> `deploy.sh` does not run them.

### Update a Single Service

```bash
cd /opt/trackhub

# Pull latest code for the service (use the matching repo name)
# authority → TrackHub.AuthorityServer | security → TrackHubSecurity
# manager → TrackHub.Manager | router → TrackHubRouter
# geofencing → TrackHub.Geofencing | telemetry → TrackHub.Telemetry
# reporting → TrackHub.Reporting | syncworker → TrackHubRouter
# frontend → TrackHub | deployment → TrackHub.Deployment
cd TrackHub.Manager && git pull
cd /opt/trackhub/TrackHub.Deployment

# Rebuild and restart the service
./scripts/update-service.sh manager
```

Valid service names: `frontend`, `authority`, `security`, `manager`, `router`,
`geofencing`, `telemetry`, `reporting`, `syncworker`, `nginx`.

> `syncworker` is built from the `TrackHubRouter` repo, so a Router code change means
> updating **both** `router` and `syncworker`.

---

## Common Commands

| Action | Command |
|--------|---------|
| Check the platform status | Open `https://your-domain.com/status` (no sign-in needed) |
| View all logs | `./scripts/logs.sh` |
| View one service log | `./scripts/logs.sh manager` |
| Restart a service | `docker compose restart manager` |
| Stop everything | `docker compose down --remove-orphans` |
| Deploy/start everything | `./scripts/deploy.sh full --build` |
| Backup databases | `./scripts/backup-database.sh backup` (dumps **both** databases into one `.tar.gz`) |
| List backups | `./scripts/backup-database.sh list` |
| Restore | `./scripts/backup-database.sh restore backups/database/<file>.tar.gz` |
| Find the documents volume | `docker volume ls \| grep manager-documents` |
| Back up uploaded documents | `docker run --rm -v <that-volume>:/d -v "$PWD/backups:/b" alpine tar czf /b/documents.tar.gz -C /d .` |
| Tag a version | `./scripts/rollback.sh tag <service> v1.0.0` |
| Rollback | `./scripts/rollback.sh rollback <service> v1.0.0` |

---

## Troubleshooting

**Containers won't start?**
```bash
docker compose logs --tail=50
```

**Database connection fails?**
- Verify PostgreSQL allows remote connections (`pg_hba.conf`)
- Check connection strings in `.env` — the user field must be `user id=` (with a space)
- Test: `docker exec -it trackhub-authority env | grep ConnectionStrings`
  (only the `db-init` container has `DB_CONNECTION_*` vars; the services receive
  `ConnectionStrings__*`)

**`db-init` fails / "relation does not exist"?**

You almost certainly skipped **Step 5** — the EF migrations. `db-init` seeds data only; it
does not create tables. Apply the migrations, then re-run `./scripts/deploy.sh full --build`.

**Never run `docker compose down -v`.**

The `-v` flag deletes the volumes, which destroys **every uploaded document** (the
`manager-documents` volume — this data is *not* in PostgreSQL and not covered by
`backup-database.sh`) and removes the `db-init` flag, which re-arms the one-time
User/Account ID sync on the next deploy. Use `docker compose down --remove-orphans`.

**Certificate errors?**
```bash
ls -la certificates/
openssl x509 -in certificates/fullchain.pem -text -noout
```

**CORS errors in browser?**
- Check `ALLOWED_CORS_ORIGINS` matches your URL exactly (including `https://`)

**A service still runs old code after an update?**

Builds detect source changes automatically and containers are always
force-recreated, so this is rare. If you suspect a problem:
```bash
# Confirm the latest code was pulled
git -C /opt/trackhub/TrackHub.Manager log -1 --oneline

# Rebuild and redeploy (optionally force a full rebuild)
./scripts/deploy.sh full --build            # normal
./scripts/deploy.sh full --build --no-cache # only if you must bypass the cache
```
You do **not** need to manually delete repos, remove volumes, or run the deploy
multiple times.

---

For the full deployment guide with advanced options, split-server setups, and migration instructions, see [INSTALL.md](INSTALL.md).
