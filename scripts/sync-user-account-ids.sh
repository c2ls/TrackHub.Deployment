#!/bin/bash
# =============================================================================
# TrackHub User/Account ID Synchronization Script
# =============================================================================
# Synchronizes User and Account IDs between TrackHubSecurity and TrackHub databases
# This must be run AFTER the database initialization is complete
#
# What it does:
# 1. Copies the user ID from TrackHubSecurity.security.users to TrackHub.app.users
# 2. Copies the account ID from TrackHub.app.accounts to TrackHubSecurity.security.users
# =============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_success() { echo -e "${GREEN}✓ $1${NC}"; }
print_warning() { echo -e "${YELLOW}⚠ $1${NC}"; }
print_error() { echo -e "${RED}✗ $1${NC}"; }
print_info() { echo -e "${BLUE}ℹ $1${NC}"; }

# Parse arguments: an optional env-file path and the --yes flag, in any order
AUTO_YES=""
ENV_FILE=""
for arg in "$@"; do
    case "$arg" in
        --yes) AUTO_YES=1 ;;
        *) ENV_FILE="$arg" ;;
    esac
done
ENV_FILE="${ENV_FILE:-$PROJECT_DIR/.env}"

# Load environment. Inside the db-init container there is no .env file — the
# DB_CONNECTION_* variables arrive via the container environment instead.
if [ -f "$ENV_FILE" ]; then
    print_info "Loading environment from: $ENV_FILE"
    set -a
    source "$ENV_FILE"
    set +a
elif [ -n "$DB_CONNECTION_SECURITY" ] && [ -n "$DB_CONNECTION_MANAGER" ]; then
    print_info "No env file at $ENV_FILE; using DB_CONNECTION_* from the environment"
else
    print_error "Environment file not found: $ENV_FILE"
    print_info "Usage: $0 [path-to-env-file] [--yes]"
    exit 1
fi

# Parse connection strings
# Format: server=host;user id=user;password=pass;database=db;port=port
parse_connection_string() {
    local conn_str="$1"
    local field="$2"
    
    echo "$conn_str" | tr ';' '\n' | grep -i "^$field=" | cut -d'=' -f2-
}

# Extract connection details
SECURITY_HOST=$(parse_connection_string "$DB_CONNECTION_SECURITY" "server")
SECURITY_USER=$(parse_connection_string "$DB_CONNECTION_SECURITY" "user id")
SECURITY_PASS=$(parse_connection_string "$DB_CONNECTION_SECURITY" "password")
SECURITY_DB=$(parse_connection_string "$DB_CONNECTION_SECURITY" "database")
SECURITY_PORT=$(parse_connection_string "$DB_CONNECTION_SECURITY" "port")

MANAGER_HOST=$(parse_connection_string "$DB_CONNECTION_MANAGER" "server")
MANAGER_USER=$(parse_connection_string "$DB_CONNECTION_MANAGER" "user id")
MANAGER_PASS=$(parse_connection_string "$DB_CONNECTION_MANAGER" "password")
MANAGER_DB=$(parse_connection_string "$DB_CONNECTION_MANAGER" "database")
MANAGER_PORT=$(parse_connection_string "$DB_CONNECTION_MANAGER" "port")

# Set defaults
SECURITY_PORT=${SECURITY_PORT:-5432}
MANAGER_PORT=${MANAGER_PORT:-5432}

print_info "Security DB: $SECURITY_HOST:$SECURITY_PORT/$SECURITY_DB"
print_info "Manager DB: $MANAGER_HOST:$MANAGER_PORT/$MANAGER_DB"

# Function to run SQL on security database
run_security_sql() {
    PGPASSWORD="$SECURITY_PASS" psql -h "$SECURITY_HOST" -p "$SECURITY_PORT" -U "$SECURITY_USER" -d "$SECURITY_DB" -t -A -c "$1"
}

# Function to run SQL on manager database
run_manager_sql() {
    PGPASSWORD="$MANAGER_PASS" psql -h "$MANAGER_HOST" -p "$MANAGER_PORT" -U "$MANAGER_USER" -d "$MANAGER_DB" -t -A -c "$1"
}

echo ""
echo "=============================================="
echo "  TrackHub User/Account ID Synchronization"
echo "=============================================="
echo ""

# Check if psql is available
if ! command -v psql &> /dev/null; then
    print_error "PostgreSQL client (psql) is not installed"
    print_info "Install it with: sudo apt install postgresql-client"
    exit 1
fi

# Test database connectivity
print_info "Testing database connectivity..."

if ! run_security_sql "SELECT 1;" > /dev/null 2>&1; then
    print_error "Cannot connect to Security database"
    exit 1
fi
print_success "Connected to Security database"

if ! run_manager_sql "SELECT 1;" > /dev/null 2>&1; then
    print_error "Cannot connect to Manager database"
    exit 1
fi
print_success "Connected to Manager database"

echo ""

# Step 1: Get the user ID from the Security database
print_info "Step 1: Getting user ID from TrackHubSecurity.security.user..."

SECURITY_USER_ID=$(run_security_sql "SELECT id FROM security.users LIMIT 1;")

if [ -z "$SECURITY_USER_ID" ]; then
    print_error "No user found in security.users table"
    print_info "Make sure the database has been initialized with seed data"
    exit 1
fi

print_success "Found security user ID: $SECURITY_USER_ID"

# Step 2: Get the current user ID from the Manager database
print_info "Step 2: Getting current user ID from TrackHub.app.user..."

MANAGER_USER_ID=$(run_manager_sql "SELECT userid FROM app.users LIMIT 1;")

if [ -z "$MANAGER_USER_ID" ]; then
    print_error "No user found in app.users table"
    print_info "Make sure the database has been initialized with seed data"
    exit 1
fi

print_info "Current manager user ID: $MANAGER_USER_ID"

# Step 3: Get the account ID from the Manager database
print_info "Step 3: Getting account ID from TrackHub.app.accounts..."

ACCOUNT_ID=$(run_manager_sql "SELECT accountid FROM app.accounts LIMIT 1;")

if [ -z "$ACCOUNT_ID" ]; then
    print_error "No account found in app.accounts table"
    print_info "Make sure the database has been initialized with seed data"
    exit 1
fi

print_success "Found account ID: $ACCOUNT_ID"

echo ""
print_info "Summary of changes to be made:"
echo "  - Update TrackHub.app.user.userid: $MANAGER_USER_ID -> $SECURITY_USER_ID"
echo "  - Update TrackHub.app.user_settings.userid: $MANAGER_USER_ID -> $SECURITY_USER_ID"
echo "  - Update TrackHubSecurity.security.user.accountid: -> $ACCOUNT_ID"
echo ""

# Confirmation prompt (skip if --yes flag is provided)
if [ -z "$AUTO_YES" ]; then
    read -p "Do you want to proceed with these changes? (y/N) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        print_warning "Operation cancelled"
        exit 0
    fi
fi

echo ""

# Step 4: Update user ID in Manager database
print_info "Step 4: Updating user ID in TrackHub.app.user..."

run_manager_sql "UPDATE app.users SET userid = '$SECURITY_USER_ID' WHERE userid = '$MANAGER_USER_ID';"
print_success "Updated app.users"

# Step 5: Update user ID in user_settings table
print_info "Step 5: Updating user ID in TrackHub.app.user_settings..."

run_manager_sql "UPDATE app.user_settings SET userid = '$SECURITY_USER_ID' WHERE userid = '$MANAGER_USER_ID';"
print_success "Updated app.user_settings"

# Step 6: Update account ID in Security database
print_info "Step 6: Updating account ID in TrackHubSecurity.security.user..."

run_security_sql "UPDATE security.users SET accountid = '$ACCOUNT_ID' WHERE id = '$SECURITY_USER_ID';"
print_success "Updated security.users"

echo ""
echo "=============================================="
print_success "User/Account ID synchronization complete!"
echo "=============================================="
echo ""
print_info "Synchronized values:"
echo "  User ID: $SECURITY_USER_ID"
echo "  Account ID: $ACCOUNT_ID"
echo ""
