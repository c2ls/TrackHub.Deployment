#!/bin/bash
# =============================================================================
# TrackHub Database Initialization Script
# =============================================================================
# This script runs during initial deployment to:
# 1. Create and seed the TrackHubSecurity database (ClientSeeder)
# 2. Initialize the TrackHubSecurity database structure (Security DBInitializer)
# 3. Create and initialize the TrackHub database (Manager DBInitializer)
# =============================================================================

set -e

FLAG_FILE="/app/flags/db-initialized"

# Check if already initialized
if [ -f "$FLAG_FILE" ]; then
    echo "=========================================="
    echo "Database already initialized. Skipping..."
    echo "=========================================="
    exit 0
fi

echo "=========================================="
echo "Starting TrackHub Database Initialization"
echo "=========================================="

# Wait for database to be ready
wait_for_db() {
    local connection_string=$1
    local db_name=$2
    
    echo "Waiting for $db_name database to be ready..."
    
    # Extract host and port from connection string
    local host=$(echo "$connection_string" | grep -oP 'server=\K[^;]+')
    local port=$(echo "$connection_string" | grep -oP 'port=\K[^;]+')
    
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

dotnet TrackHub.AuthorityServer.ClientSeeder.dll || { echo "ClientSeeder failed"; exit 1; }
echo "ClientSeeder completed successfully!"

echo ""
echo "=========================================="
echo "Step 2: Running Security DBInitializer"
echo "=========================================="
cd /app/security-init

# Update connection string
cat > appsettings.json << EOF
{
  "ConnectionStrings": {
    "Security": "$DB_CONNECTION_SECURITY"
  }
}
EOF

dotnet DBInitializer.dll || { echo "Security DBInitializer failed"; exit 1; }
echo "Security DBInitializer completed successfully!"

echo ""
echo "=========================================="
echo "Step 3: Running Manager DBInitializer"
echo "=========================================="
cd /app/manager-init

# Update connection string
cat > appsettings.json << EOF
{
  "ConnectionStrings": {
    "DefaultConnection": "$DB_CONNECTION_MANAGER"
  }
}
EOF

dotnet DBInitializer.dll || { echo "Manager DBInitializer failed"; exit 1; }
echo "Manager DBInitializer completed successfully!"

echo ""
echo "=========================================="
echo "Database Initialization Complete!"
echo "=========================================="
echo ""

# Step 4: Sync User and Account IDs
print_info "Step 4: Synchronizing User and Account IDs..."

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
    SECURITY_USER_ID=$(PGPASSWORD="$SEC_PASS" psql -h "$SEC_HOST" -p "$SEC_PORT" -U "$SEC_USER" -d "$SEC_DB" -t -A -c "SELECT id FROM security.\"user\" LIMIT 1;")
    
    # Get current manager user ID
    MANAGER_USER_ID=$(PGPASSWORD="$MGR_PASS" psql -h "$MGR_HOST" -p "$MGR_PORT" -U "$MGR_USER" -d "$MGR_DB" -t -A -c "SELECT userid FROM app.\"user\" LIMIT 1;")
    
    # Get account ID
    ACCOUNT_ID=$(PGPASSWORD="$MGR_PASS" psql -h "$MGR_HOST" -p "$MGR_PORT" -U "$MGR_USER" -d "$MGR_DB" -t -A -c "SELECT accountid FROM app.account LIMIT 1;")
    
    if [ -n "$SECURITY_USER_ID" ] && [ -n "$MANAGER_USER_ID" ] && [ -n "$ACCOUNT_ID" ]; then
        echo "Security User ID: $SECURITY_USER_ID"
        echo "Manager User ID: $MANAGER_USER_ID"
        echo "Account ID: $ACCOUNT_ID"
        
        # Update manager database
        PGPASSWORD="$MGR_PASS" psql -h "$MGR_HOST" -p "$MGR_PORT" -U "$MGR_USER" -d "$MGR_DB" -c "UPDATE app.\"user\" SET userid = '$SECURITY_USER_ID' WHERE userid = '$MANAGER_USER_ID';"
        PGPASSWORD="$MGR_PASS" psql -h "$MGR_HOST" -p "$MGR_PORT" -U "$MGR_USER" -d "$MGR_DB" -c "UPDATE app.user_settings SET userid = '$SECURITY_USER_ID' WHERE userid = '$MANAGER_USER_ID';"
        
        # Update security database
        PGPASSWORD="$SEC_PASS" psql -h "$SEC_HOST" -p "$SEC_PORT" -U "$SEC_USER" -d "$SEC_DB" -c "UPDATE security.\"user\" SET accountid = '$ACCOUNT_ID' WHERE id = '$SECURITY_USER_ID';"
        
        echo "User/Account IDs synchronized successfully!"
    else
        echo "WARNING: Could not sync User/Account IDs automatically."
        echo "Please run the sync manually after deployment."
    fi
fi

echo ""

# Create flag file to prevent re-initialization
touch "$FLAG_FILE"

echo "Initialization flag created. Database will not be re-initialized on restart."
