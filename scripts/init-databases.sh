#!/bin/bash
# =============================================================================
# TrackHub Database Initialization Script
# =============================================================================
# Runs on every deploy (new installations AND updates). It performs:
#   1. ClientSeeder            - OpenIddict scopes + OAuth clients (idempotent upsert)
#   2. Security DBInitializer  - security resources/roles/service-client seed (idempotent)
#   3. Manager DBInitializer   - master data seed: reports, transporter types, etc. (idempotent)
#   4. User/Account ID sync    - ONE-TIME destructive fix, guarded by a flag file
#
# Steps 1-3 are safe to re-run: the seeders upsert / guard every insert with an
# existence check, so on updates they simply add anything new (e.g. newly
# introduced OAuth clients or permission resources) and leave existing data
# untouched. Only the destructive ID sync (step 4) is gated by the flag file.
#
# NOTE: EF schema migrations ("DB updates") are applied separately from this
# script (the seeders assume the schema already exists). See INSTALL.md ->
# Database Migrations. ClientSeeder creates the OpenIddict tables it needs via
# EnsureCreated.
# =============================================================================

set -e

FLAG_FILE="/app/flags/db-initialized"

# Colors / logging helpers
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_success() { echo -e "${GREEN}✓ $1${NC}"; }
print_warning() { echo -e "${YELLOW}⚠ $1${NC}"; }
print_error()   { echo -e "${RED}✗ $1${NC}"; }
print_info()    { echo -e "${BLUE}ℹ $1${NC}"; }

echo "=========================================="
echo "Starting TrackHub Database Initialization"
echo "=========================================="

# Wait for database to be ready
wait_for_db() {
    local connection_string=$1
    local db_name=$2

    echo "Waiting for $db_name database to be ready..."

    # Extract host and port from connection string
    local host
    local port
    host=$(echo "$connection_string" | grep -oP 'server=\K[^;]+')
    port=$(echo "$connection_string" | grep -oP 'port=\K[^;]+')
    port=${port:-5432}

    local max_attempts=30
    local attempt=1

    while [ $attempt -le $max_attempts ]; do
        if pg_isready -h "$host" -p "$port" > /dev/null 2>&1; then
            echo "$db_name database is ready!"
            return 0
        fi
        echo "Attempt $attempt/$max_attempts: $db_name database not ready yet..."
        sleep 5
        attempt=$((attempt + 1))
    done

    echo "ERROR: $db_name database did not become ready in time"
    return 1
}

# Wait for database
wait_for_db "$DB_CONNECTION_SECURITY" "Security"

# -----------------------------------------------------------------------------
# Step 1: ClientSeeder (idempotent - runs every deploy)
# -----------------------------------------------------------------------------
echo ""
echo "=========================================="
echo "Step 1: Running ClientSeeder"
echo "=========================================="
cd /app/client-seeder

# Update connection string in appsettings
cat > appsettings.json << EOF
{
  "ConnectionStrings": {
    "Security": "$DB_CONNECTION_SECURITY"
  }
}
EOF

# Copy clients.json if provided
if [ -f "/app/clients.json" ]; then
    cp /app/clients.json ./clients.json
    echo "Using provided clients.json"
else
    echo "WARNING: No clients.json provided. Using default configuration."
fi

dotnet TrackHub.AuthorityServer.ClientSeeder.dll || { print_error "ClientSeeder failed"; exit 1; }
print_success "ClientSeeder completed successfully!"

# -----------------------------------------------------------------------------
# Step 2: Security DBInitializer (idempotent - runs every deploy)
# -----------------------------------------------------------------------------
echo ""
echo "=========================================="
echo "Step 2: Running Security DBInitializer"
echo "=========================================="
cd /app/security-init

cat > appsettings.json << EOF
{
  "ConnectionStrings": {
    "Security": "$DB_CONNECTION_SECURITY"
  }
}
EOF

dotnet DBInitializer.dll || { print_error "Security DBInitializer failed"; exit 1; }
print_success "Security DBInitializer completed successfully!"

# -----------------------------------------------------------------------------
# Step 3: Manager DBInitializer (idempotent - runs every deploy)
# -----------------------------------------------------------------------------
echo ""
echo "=========================================="
echo "Step 3: Running Manager DBInitializer"
echo "=========================================="
cd /app/manager-init

cat > appsettings.json << EOF
{
  "ConnectionStrings": {
    "DefaultConnection": "$DB_CONNECTION_MANAGER"
  }
}
EOF

dotnet DBInitializer.dll || { print_error "Manager DBInitializer failed"; exit 1; }
print_success "Manager DBInitializer completed successfully!"

echo ""
echo "=========================================="
echo "Seeding Complete!"
echo "=========================================="
echo ""

# -----------------------------------------------------------------------------
# Step 4: Sync User and Account IDs (ONE-TIME, destructive - guarded by flag)
# -----------------------------------------------------------------------------
if [ -f "$FLAG_FILE" ]; then
    print_info "User/Account ID sync already performed (flag present). Skipping step 4."
    echo ""
    echo "Initialization complete (seed refreshed; one-time sync skipped)."
    exit 0
fi

print_info "Step 4: Synchronizing User and Account IDs (one-time)..."

# Wait a moment for database transactions to settle
sleep 2

# Run the sync script
if [ -f "/app/sync-user-account-ids.sh" ]; then
    chmod +x /app/sync-user-account-ids.sh
    /app/sync-user-account-ids.sh --yes
    echo ""
    print_success "User/Account ID synchronization completed!"
else
    # Inline sync if script not available
    echo "Performing inline User/Account ID sync..."

    # Parse connection strings
    parse_conn() {
        echo "$1" | tr ';' '\n' | grep -i "^$2=" | cut -d'=' -f2-
    }

    SEC_HOST=$(parse_conn "$DB_CONNECTION_SECURITY" "server")
    SEC_USER=$(parse_conn "$DB_CONNECTION_SECURITY" "user id")
    SEC_PASS=$(parse_conn "$DB_CONNECTION_SECURITY" "password")
    SEC_DB=$(parse_conn "$DB_CONNECTION_SECURITY" "database")
    SEC_PORT=$(parse_conn "$DB_CONNECTION_SECURITY" "port")
    SEC_PORT=${SEC_PORT:-5432}

    MGR_HOST=$(parse_conn "$DB_CONNECTION_MANAGER" "server")
    MGR_USER=$(parse_conn "$DB_CONNECTION_MANAGER" "user id")
    MGR_PASS=$(parse_conn "$DB_CONNECTION_MANAGER" "password")
    MGR_DB=$(parse_conn "$DB_CONNECTION_MANAGER" "database")
    MGR_PORT=$(parse_conn "$DB_CONNECTION_MANAGER" "port")
    MGR_PORT=${MGR_PORT:-5432}

    # Get security user ID
    SECURITY_USER_ID=$(PGPASSWORD="$SEC_PASS" psql -h "$SEC_HOST" -p "$SEC_PORT" -U "$SEC_USER" -d "$SEC_DB" -t -A -c "SELECT id FROM security.users LIMIT 1;")

    # Get current manager user ID
    MANAGER_USER_ID=$(PGPASSWORD="$MGR_PASS" psql -h "$MGR_HOST" -p "$MGR_PORT" -U "$MGR_USER" -d "$MGR_DB" -t -A -c "SELECT userid FROM app.users LIMIT 1;")

    # Get account ID
    ACCOUNT_ID=$(PGPASSWORD="$MGR_PASS" psql -h "$MGR_HOST" -p "$MGR_PORT" -U "$MGR_USER" -d "$MGR_DB" -t -A -c "SELECT accountid FROM app.accounts LIMIT 1;")

    if [ -n "$SECURITY_USER_ID" ] && [ -n "$MANAGER_USER_ID" ] && [ -n "$ACCOUNT_ID" ]; then
        echo "Security User ID: $SECURITY_USER_ID"
        echo "Manager User ID: $MANAGER_USER_ID"
        echo "Account ID: $ACCOUNT_ID"

        # Update manager database
        PGPASSWORD="$MGR_PASS" psql -h "$MGR_HOST" -p "$MGR_PORT" -U "$MGR_USER" -d "$MGR_DB" -c "UPDATE app.users SET userid = '$SECURITY_USER_ID' WHERE userid = '$MANAGER_USER_ID';"
        PGPASSWORD="$MGR_PASS" psql -h "$MGR_HOST" -p "$MGR_PORT" -U "$MGR_USER" -d "$MGR_DB" -c "UPDATE app.user_settings SET userid = '$SECURITY_USER_ID' WHERE userid = '$MANAGER_USER_ID';"

        # Update security database
        PGPASSWORD="$SEC_PASS" psql -h "$SEC_HOST" -p "$SEC_PORT" -U "$SEC_USER" -d "$SEC_DB" -c "UPDATE security.users SET accountid = '$ACCOUNT_ID' WHERE id = '$SECURITY_USER_ID';"

        echo "User/Account IDs synchronized successfully!"
    else
        print_warning "Could not sync User/Account IDs automatically."
        echo "Please run the sync manually after deployment."
    fi
fi

echo ""

# Create flag file to prevent re-running the one-time sync
touch "$FLAG_FILE"

print_success "Initialization flag created. The one-time User/Account ID sync will not run again."
