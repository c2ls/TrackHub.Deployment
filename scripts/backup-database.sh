#!/bin/bash
# =============================================================================
# TrackHub Database Backup Script
# =============================================================================
# Creates backups of PostgreSQL databases (TrackHubSecurity and TrackHub)
# Supports full backups, scheduled backups, and restoration
#
# Usage:
#   ./backup-database.sh backup              # Create backup
#   ./backup-database.sh restore <file>      # Restore from backup
#   ./backup-database.sh list                # List available backups
#   ./backup-database.sh cleanup [days]      # Remove old backups (default: 30 days)
# =============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BACKUP_DIR="${BACKUP_DIR:-$PROJECT_DIR/backups/database}"
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")

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

# Load environment
ENV_FILE="$PROJECT_DIR/.env"
if [ -f "$ENV_FILE" ]; then
    set -a
    source "$ENV_FILE"
    set +a
fi

# Parse connection string
parse_connection_string() {
    local conn_str="$1"
    local field="$2"
    echo "$conn_str" | tr ';' '\n' | grep -i "^$field=" | cut -d'=' -f2-
}

# Create backup directory
mkdir -p "$BACKUP_DIR"

backup_database() {
    local conn_str="$1"
    local db_name="$2"
    local output_file="$3"
    
    local host=$(parse_connection_string "$conn_str" "server")
    local user=$(parse_connection_string "$conn_str" "user id")
    local pass=$(parse_connection_string "$conn_str" "password")
    local db=$(parse_connection_string "$conn_str" "database")
    local port=$(parse_connection_string "$conn_str" "port")
    port=${port:-5432}
    
    print_info "Backing up $db_name ($db)..."
    
    PGPASSWORD="$pass" pg_dump -h "$host" -p "$port" -U "$user" -d "$db" \
        --format=custom --compress=9 --verbose \
        -f "$output_file" 2>&1 | tail -5
    
    if [ -f "$output_file" ]; then
        local size=$(du -h "$output_file" | cut -f1)
        print_success "Backup created: $output_file ($size)"
    else
        print_error "Backup failed for $db_name"
        return 1
    fi
}

restore_database() {
    local conn_str="$1"
    local db_name="$2"
    local input_file="$3"
    
    local host=$(parse_connection_string "$conn_str" "server")
    local user=$(parse_connection_string "$conn_str" "user id")
    local pass=$(parse_connection_string "$conn_str" "password")
    local db=$(parse_connection_string "$conn_str" "database")
    local port=$(parse_connection_string "$conn_str" "port")
    port=${port:-5432}
    
    print_warning "This will restore $db_name from backup."
    print_warning "Existing data may be overwritten!"
    read -p "Are you sure? (y/N) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        print_info "Restore cancelled"
        return 0
    fi
    
    print_info "Restoring $db_name from $input_file..."
    
    PGPASSWORD="$pass" pg_restore -h "$host" -p "$port" -U "$user" -d "$db" \
        --clean --if-exists --verbose \
        "$input_file" 2>&1 | tail -10
    
    print_success "Restore completed for $db_name"
}

do_backup() {
    echo ""
    echo "=============================================="
    echo "  TrackHub Database Backup"
    echo "=============================================="
    echo ""
    
    # Check for pg_dump
    if ! command -v pg_dump &> /dev/null; then
        print_error "pg_dump not found. Install postgresql-client."
        exit 1
    fi
    
    local backup_subdir="$BACKUP_DIR/$TIMESTAMP"
    mkdir -p "$backup_subdir"
    
    # Backup Security database
    backup_database "$DB_CONNECTION_SECURITY" "TrackHubSecurity" \
        "$backup_subdir/trackhub_security_$TIMESTAMP.dump"
    
    # Backup Manager database
    backup_database "$DB_CONNECTION_MANAGER" "TrackHub" \
        "$backup_subdir/trackhub_manager_$TIMESTAMP.dump"
    
    # Create a combined archive
    print_info "Creating combined archive..."
    tar -czf "$BACKUP_DIR/trackhub_backup_$TIMESTAMP.tar.gz" -C "$BACKUP_DIR" "$TIMESTAMP"
    rm -rf "$backup_subdir"
    
    echo ""
    print_success "Backup complete: $BACKUP_DIR/trackhub_backup_$TIMESTAMP.tar.gz"
    echo ""
    
    # Show backup size
    ls -lh "$BACKUP_DIR/trackhub_backup_$TIMESTAMP.tar.gz"
}

do_restore() {
    local backup_file="$1"
    
    if [ -z "$backup_file" ]; then
        print_error "Please specify a backup file"
        echo "Usage: $0 restore <backup_file.tar.gz>"
        exit 1
    fi
    
    if [ ! -f "$backup_file" ]; then
        print_error "Backup file not found: $backup_file"
        exit 1
    fi
    
    echo ""
    echo "=============================================="
    echo "  TrackHub Database Restore"
    echo "=============================================="
    echo ""
    
    # Extract backup
    local temp_dir=$(mktemp -d)
    tar -xzf "$backup_file" -C "$temp_dir"
    
    # Find the extracted directory
    local extracted_dir=$(ls "$temp_dir")
    
    # Restore Security database
    local security_dump=$(find "$temp_dir" -name "*security*.dump" | head -1)
    if [ -f "$security_dump" ]; then
        restore_database "$DB_CONNECTION_SECURITY" "TrackHubSecurity" "$security_dump"
    fi
    
    # Restore Manager database
    local manager_dump=$(find "$temp_dir" -name "*manager*.dump" | head -1)
    if [ -f "$manager_dump" ]; then
        restore_database "$DB_CONNECTION_MANAGER" "TrackHub" "$manager_dump"
    fi
    
    # Cleanup
    rm -rf "$temp_dir"
    
    echo ""
    print_success "Restore process complete"
}

do_list() {
    echo ""
    echo "Available backups in $BACKUP_DIR:"
    echo "=================================="
    
    if [ -d "$BACKUP_DIR" ]; then
        ls -lht "$BACKUP_DIR"/*.tar.gz 2>/dev/null || echo "No backups found"
    else
        echo "Backup directory does not exist"
    fi
    echo ""
}

do_cleanup() {
    local days="${1:-30}"
    
    echo ""
    print_info "Removing backups older than $days days..."
    
    local count=$(find "$BACKUP_DIR" -name "*.tar.gz" -mtime +$days 2>/dev/null | wc -l)
    
    if [ "$count" -gt 0 ]; then
        find "$BACKUP_DIR" -name "*.tar.gz" -mtime +$days -delete
        print_success "Removed $count old backup(s)"
    else
        print_info "No backups older than $days days found"
    fi
}

# Main
case "${1:-backup}" in
    backup)
        do_backup
        ;;
    restore)
        do_restore "$2"
        ;;
    list)
        do_list
        ;;
    cleanup)
        do_cleanup "$2"
        ;;
    *)
        echo "Usage: $0 {backup|restore|list|cleanup}"
        echo ""
        echo "Commands:"
        echo "  backup              Create a new backup"
        echo "  restore <file>      Restore from a backup file"
        echo "  list                List available backups"
        echo "  cleanup [days]      Remove backups older than N days (default: 30)"
        exit 1
        ;;
esac
