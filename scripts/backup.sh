#!/bin/bash
# =============================================================================
# TrackHub Backup Script
# =============================================================================
# Create backups of configuration and data
# =============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BACKUP_DIR="$PROJECT_DIR/backups"
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")

# Colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

print_success() {
    echo -e "${GREEN}✓ $1${NC}"
}

print_info() {
    echo -e "${BLUE}ℹ $1${NC}"
}

# Create backup directory
mkdir -p "$BACKUP_DIR"

print_info "Creating backup: $TIMESTAMP"

# Backup configuration files
BACKUP_FILE="$BACKUP_DIR/trackhub_config_$TIMESTAMP.tar.gz"

tar -czf "$BACKUP_FILE" \
    -C "$PROJECT_DIR" \
    .env \
    config/ \
    nginx/ \
    2>/dev/null || true

print_success "Configuration backup created: $BACKUP_FILE"

# List recent backups
print_info "Recent backups:"
ls -lh "$BACKUP_DIR"/*.tar.gz 2>/dev/null | tail -5

# Cleanup old backups (keep last 10)
print_info "Cleaning up old backups (keeping last 10)..."
cd "$BACKUP_DIR"
ls -t *.tar.gz 2>/dev/null | tail -n +11 | xargs -r rm --

print_success "Backup complete!"
