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
git clone https://github.com/shernandezp/TrackHub.git
git clone https://github.com/shernandezp/TrackHub.AuthorityServer.git
git clone https://github.com/shernandezp/TrackHubSecurity.git
git clone https://github.com/shernandezp/TrackHub.Manager.git
git clone https://github.com/shernandezp/TrackHubRouter.git
git clone https://github.com/shernandezp/TrackHub.Geofencing.git
git clone https://github.com/shernandezp/TrackHub.Reporting.git
```

---

## Step 3: Prepare the Database

Connect to PostgreSQL and create the required databases:

```sql
CREATE DATABASE "TrackHubSecurity";
CREATE DATABASE "TrackHub";

-- Create a user (adjust password)
CREATE USER trackhub WITH PASSWORD 'YourStrongPassword';
GRANT ALL PRIVILEGES ON DATABASE "TrackHubSecurity" TO trackhub;
GRANT ALL PRIVILEGES ON DATABASE "TrackHub" TO trackhub;
```

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
| `DB_CONNECTION_SECURITY` | `server=DB_HOST;port=5432;database=TrackHubSecurity;userid=trackhub;password=YourStrongPassword` |
| `DB_CONNECTION_MANAGER` | `server=DB_HOST;port=5432;database=TrackHub;userid=trackhub;password=YourStrongPassword` |
| `DB_CONNECTION_LOGGING` | `server=DB_HOST;port=5432;database=TrackHub;userid=trackhub;password=YourStrongPassword` |
| `CERTIFICATE_PASSWORD` | A strong password for the token-signing certificate |
| `ENCRYPTION_KEY` | A GUID (generate with `uuidgen` or any GUID tool) |
| `AUTHORITY_URL` | `https://trackhub.example.com/Identity` |

Replace `DB_HOST` with your PostgreSQL server address (`localhost` if on the same server).

---

## Step 5: Generate Certificates

```bash
chmod +x scripts/*.sh
```

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

## Step 6: Configure OAuth Clients

```bash
cp config/clients.json.example config/clients.json
nano config/clients.json
```

Update the callback URIs to use your domain:

```
https://your-domain.com/callback
```

---

## Step 7: Deploy

```bash
./scripts/deploy.sh full --build
```

This builds all containers without Docker layer cache and force recreates the running containers from the newly built images. First run takes several minutes.

---

## Step 8: Verify

```bash
# Check all containers are running
docker compose ps

# Check service health
./scripts/health-check.sh your-domain.com
```

Open `https://your-domain.com` in your browser. You should see the TrackHub login page.

---

## Updating TrackHub

### Update Everything

```bash
cd /opt/trackhub

# Pull latest code for all repos
for repo in TrackHub TrackHub.AuthorityServer TrackHubSecurity TrackHub.Manager TrackHubRouter TrackHub.Geofencing TrackHub.Reporting TrackHub.Deployment; do
  cd /opt/trackhub/$repo && git pull
done

# Rebuild and deploy
cd /opt/trackhub/TrackHub.Deployment
./scripts/deploy.sh full --build
```

### Update a Single Service

```bash
cd /opt/trackhub

# Pull latest code for the service (use the matching repo name)
# authority → TrackHub.AuthorityServer | security → TrackHubSecurity
# manager → TrackHub.Manager | router → TrackHubRouter
# geofencing → TrackHub.Geofencing | reporting → TrackHub.Reporting
# frontend → TrackHub | deployment → TrackHub.Deployment
cd TrackHub.Manager && git pull
cd /opt/trackhub/TrackHub.Deployment

# Rebuild and restart the service
./scripts/update-service.sh manager
```

---

## Common Commands

| Action | Command |
|--------|---------|
| View all logs | `./scripts/logs.sh` |
| View one service log | `./scripts/logs.sh manager` |
| Restart a service | `docker compose restart manager` |
| Stop everything | `docker compose down --remove-orphans` |
| Deploy/start everything | `./scripts/deploy.sh full --build` |
| Backup databases | `./scripts/backup-database.sh backup security && ./scripts/backup-database.sh backup manager` |
| Tag a version | `./scripts/rollback.sh tag v1.0.0` |
| Rollback | `./scripts/rollback.sh rollback v1.0.0` |

---

## Troubleshooting

**Containers won't start?**
```bash
docker compose logs --tail=50
```

**Database connection fails?**
- Verify PostgreSQL allows remote connections (`pg_hba.conf`)
- Check connection strings in `.env`
- Test: `docker exec -it trackhub-authority env | grep DB_`

**Certificate errors?**
```bash
ls -la certificates/
openssl x509 -in certificates/fullchain.pem -text -noout
```

**CORS errors in browser?**
- Check `ALLOWED_CORS_ORIGINS` matches your URL exactly (including `https://`)

---

For the full deployment guide with advanced options, split-server setups, and migration instructions, see [INSTALL.md](INSTALL.md).
