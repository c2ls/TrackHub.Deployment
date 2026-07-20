#!/bin/bash
# =============================================================================
# TrackHub SSL Certificate Renewal Script
# =============================================================================
# Automatically renews Let's Encrypt certificates using webroot method
# (no nginx downtime required).
# Add to crontab for automatic renewal:
#   0 3 * * * /opt/trackhub/TrackHub.Deployment/scripts/renew-ssl.sh >> /var/log/trackhub-ssl-renewal.log 2>&1
# =============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
CERT_DIR="$PROJECT_DIR/certificates"
WEBROOT="$PROJECT_DIR/certbot/webroot"

# Colors (disabled if not interactive)
if [ -t 1 ]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    NC='\033[0m'
else
    RED=''
    GREEN=''
    YELLOW=''
    BLUE=''
    NC=''
fi

print_success() { echo -e "${GREEN}✓ $1${NC}"; }
print_warning() { echo -e "${YELLOW}⚠ $1${NC}"; }
print_error() { echo -e "${RED}✗ $1${NC}"; }
print_info() { echo -e "${BLUE}ℹ $1${NC}"; }

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

# Load environment
if [ -f "$PROJECT_DIR/.env" ]; then
    set -a
    source "$PROJECT_DIR/.env"
    set +a
fi

DOMAIN="${DOMAIN:-}"

if [ -z "$DOMAIN" ]; then
    print_error "DOMAIN not set in .env file"
    exit 1
fi

log "Starting SSL certificate renewal check for $DOMAIN"

# Check if certbot is installed
if ! command -v certbot &> /dev/null; then
    print_error "certbot is not installed. Run: apt install certbot"
    exit 1
fi

# Check certificate expiration
check_expiration() {
    local cert_file="$1"
    local days_until_expiry
    
    if [ ! -f "$cert_file" ]; then
        echo "0"
        return
    fi
    
    days_until_expiry=$(openssl x509 -in "$cert_file" -noout -enddate 2>/dev/null | \
        cut -d= -f2 | \
        xargs -I {} date -d {} +%s | \
        xargs -I {} bash -c 'echo $(( ({} - $(date +%s)) / 86400 ))')
    
    echo "$days_until_expiry"
}

# Get days until expiry
DAYS_UNTIL_EXPIRY=$(check_expiration "$CERT_DIR/fullchain.pem")
log "Certificate expires in $DAYS_UNTIL_EXPIRY days"

# Renew if less than 30 days until expiry
if [ "$DAYS_UNTIL_EXPIRY" -lt 30 ]; then
    log "Certificate needs renewal (less than 30 days until expiry)"

    # Ensure webroot directory exists
    mkdir -p "$WEBROOT"

    # Attempt renewal using webroot (no nginx downtime)
    if certbot renew --webroot -w "$WEBROOT" --non-interactive; then
        log "Certificate renewed successfully"

        # Copy new certificates
        if [ -d "/etc/letsencrypt/live/$DOMAIN" ]; then
            cp "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" "$CERT_DIR/"
            cp "/etc/letsencrypt/live/$DOMAIN/privkey.pem" "$CERT_DIR/"
            chmod 644 "$CERT_DIR/fullchain.pem"
            chmod 600 "$CERT_DIR/privkey.pem"
            print_success "Certificates copied to $CERT_DIR"
        fi

        # Reload nginx to pick up new certificates (no downtime)
        print_info "Reloading nginx..."
        docker exec trackhub-nginx nginx -s reload 2>/dev/null || \
            docker restart trackhub-nginx 2>/dev/null || true
        print_success "Nginx reloaded with new certificates"
    else
        print_error "Certificate renewal failed"
    fi
else
    log "Certificate is still valid, no renewal needed"
fi

# Verify nginx is running
if docker ps | grep -q trackhub-nginx; then
    print_success "Nginx is running"
else
    print_warning "Nginx is not running, attempting to start..."
    cd "$PROJECT_DIR"
    docker compose up -d --force-recreate --no-build --no-deps nginx
fi

log "SSL renewal check complete"
