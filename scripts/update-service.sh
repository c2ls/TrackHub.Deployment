#!/bin/bash
# =============================================================================
# TrackHub Service Update Script
# =============================================================================
# Update individual services without affecting others.
# Service images are rebuilt using Docker layer caching (source changes are
# detected automatically) and containers are force recreated.
# Pass --no-cache to force a full rebuild ignoring the layer cache.
# Usage: ./update-service.sh <service_name> [compose_file] [--no-cache]
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

print_success() {
    echo -e "${GREEN}✓ $1${NC}"
}

print_error() {
    echo -e "${RED}✗ $1${NC}"
}

print_info() {
    echo -e "${BLUE}ℹ $1${NC}"
}

# Valid services
VALID_SERVICES=("frontend" "authority" "security" "manager" "router" "geofencing" "reporting" "syncworker" "nginx")

usage() {
    echo "Usage: $0 <service_name> [compose_file]"
    echo ""
    echo "Available services:"
    for service in "${VALID_SERVICES[@]}"; do
        echo "  - $service"
    done
    echo ""
    echo "Optional:"
    echo "  compose_file - Specify compose file (default: docker-compose.yml)"
    echo "  --no-cache   - Force a full rebuild ignoring the Docker layer cache"
    echo ""
    echo "Examples:"
    echo "  $0 frontend"
    echo "  $0 manager"
    echo "  $0 security docker-compose.backend.yml"
}

validate_service() {
    local service=$1
    for valid in "${VALID_SERVICES[@]}"; do
        if [ "$service" == "$valid" ]; then
            return 0
        fi
    done
    return 1
}

update_service() {
    local service=$1
    local compose_file=${2:-"docker-compose.yml"}
    
    cd "$PROJECT_DIR"
    
    print_info "Updating service: $service"
    
    # Check if compose file exists
    if [ ! -f "$compose_file" ]; then
        print_error "Compose file not found: $compose_file"
        exit 1
    fi
    
    # Stop the service
    print_info "Stopping $service..."
    docker compose -f "$compose_file" stop "$service" || true
    
    # Remove the container
    print_info "Removing old container..."
    docker compose -f "$compose_file" rm -f "$service" || true
    
    # Rebuild the image
    if [ "$NO_CACHE" = true ]; then
        print_info "Rebuilding $service image without Docker layer cache (--no-cache)..."
        docker compose -f "$compose_file" build --no-cache "$service"
    else
        print_info "Rebuilding $service image (layer cache detects source changes)..."
        docker compose -f "$compose_file" build "$service"
    fi
    
    # Start the service
    print_info "Starting $service..."
    docker compose -f "$compose_file" up -d --force-recreate --no-build --no-deps "$service"
    
    # Wait for health check
    print_info "Waiting for service to be healthy..."
    sleep 10
    
    # Show status
    print_info "Service status:"
    docker compose -f "$compose_file" ps "$service"
    
    print_success "Service $service updated successfully!"
}

# Check arguments
if [ $# -lt 1 ]; then
    print_error "Service name required"
    usage
    exit 1
fi

# Defaults
NO_CACHE=false
SERVICE_NAME=""
COMPOSE_FILE="docker-compose.yml"

# Parse arguments: <service_name> [compose_file] [--no-cache] in any order
for arg in "$@"; do
    case "$arg" in
        --no-cache)
            NO_CACHE=true
            ;;
        *.yml|*.yaml)
            COMPOSE_FILE="$arg"
            ;;
        *)
            if [ -z "$SERVICE_NAME" ]; then
                SERVICE_NAME="$arg"
            fi
            ;;
    esac
done

if [ -z "$SERVICE_NAME" ]; then
    print_error "Service name required"
    usage
    exit 1
fi

# Validate service name
if ! validate_service "$SERVICE_NAME"; then
    print_error "Invalid service name: $SERVICE_NAME"
    usage
    exit 1
fi

# Run update
update_service "$SERVICE_NAME" "$COMPOSE_FILE"
