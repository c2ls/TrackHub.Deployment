#!/bin/bash
# =============================================================================
# TrackHub Rollback Script
# =============================================================================
# Quickly rollback to a previous version of services
# Maintains last N versions of each service image for quick rollback
#
# Usage:
#   ./rollback.sh list                    # List available versions
#   ./rollback.sh <service> [version]     # Rollback service to version
#   ./rollback.sh all [version]           # Rollback all services
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

# Service names
SERVICES=("frontend" "authority" "security" "manager" "router" "geofencing" "telemetry" "reporting" "syncworker")

# -----------------------------------------------------------------------------
# Image name resolution
# -----------------------------------------------------------------------------
# No compose service declares an "image:" key, so Compose names the images it
# builds "<project>-<service>". The project name comes from COMPOSE_PROJECT_NAME
# or, failing that, from the normalized directory name (compose-go lowercases the
# directory name and drops every character outside [a-z0-9_-] — so
# "TrackHub.Deployment" becomes "trackhubdeployment").
# -----------------------------------------------------------------------------

COMPOSE_CONFIG_JSON=""
COMPOSE_CONFIG_LOADED=false

compose_config_json() {
    if [ "$COMPOSE_CONFIG_LOADED" = false ]; then
        COMPOSE_CONFIG_LOADED=true
        if command -v jq &> /dev/null; then
            COMPOSE_CONFIG_JSON=$( (cd "$PROJECT_DIR" && docker compose config --format json 2>/dev/null) || true)
        fi
    fi
    printf '%s' "$COMPOSE_CONFIG_JSON"
}

normalize_project_name() {
    # Mirror compose-go NormalizeProjectName: lowercase, keep only [a-z0-9_-],
    # then trim leading "_" / "-".
    printf '%s' "$1" \
        | tr '[:upper:]' '[:lower:]' \
        | tr -cd 'a-z0-9_-' \
        | sed 's/^[_-]*//'
}

PROJECT_NAME=""

get_project_name() {
    if [ -n "$PROJECT_NAME" ]; then
        printf '%s' "$PROJECT_NAME"
        return
    fi

    # 1. Explicit override from the environment
    if [ -n "${COMPOSE_PROJECT_NAME:-}" ]; then
        PROJECT_NAME="$COMPOSE_PROJECT_NAME"
    fi

    # 2. Ask Compose itself (honours .env, COMPOSE_PROJECT_NAME, "name:" in the file)
    if [ -z "$PROJECT_NAME" ]; then
        local config
        config="$(compose_config_json)"
        if [ -n "$config" ]; then
            PROJECT_NAME=$(printf '%s' "$config" | jq -r '.name // empty')
        fi
    fi
    if [ -z "$PROJECT_NAME" ]; then
        PROJECT_NAME=$( (cd "$PROJECT_DIR" && docker compose config 2>/dev/null) \
            | sed -n 's/^name:[[:space:]]*//p' | head -1 | tr -d "\"' ")
    fi

    # 3. Fall back to the normalized deployment directory name
    if [ -z "$PROJECT_NAME" ]; then
        PROJECT_NAME=$(normalize_project_name "$(basename "$PROJECT_DIR")")
    fi

    printf '%s' "$PROJECT_NAME"
}

# Resolve the image repository Compose actually uses for a service:
# the service's "image:" key when declared, otherwise "<project>-<service>".
image_name() {
    local service="$1"
    local config declared=""

    config="$(compose_config_json)"
    if [ -n "$config" ]; then
        declared=$(printf '%s' "$config" | jq -r --arg s "$service" '.services[$s].image // empty')
    fi

    if [ -n "$declared" ]; then
        # Strip any tag (but not a registry port, e.g. registry:5000/img)
        case "${declared##*/}" in
            *:*) printf '%s' "${declared%:*}" ;;
            *)   printf '%s' "$declared" ;;
        esac
        return
    fi

    printf '%s-%s' "$(get_project_name)" "$service"
}

usage() {
    echo "Usage: $0 <command> [options]"
    echo ""
    echo "Commands:"
    echo "  list                    List all service images with tags"
    echo "  history <service>       Show version history for a service"
    echo "  rollback <service> <tag> Rollback service to specific tag"
    echo "  tag <service> <tag>     Tag current version before update"
    echo ""
    echo "Services: ${SERVICES[*]}"
    echo ""
    echo "Examples:"
    echo "  $0 list"
    echo "  $0 history manager"
    echo "  $0 tag manager v1.2.0"
    echo "  $0 rollback manager v1.1.0"
}

list_images() {
    echo ""
    echo "Available TrackHub Images (compose project: $(get_project_name)):"
    echo "=========================="

    for service in "${SERVICES[@]}"; do
        local image
        image="$(image_name "$service")"
        echo ""
        print_info "$service ($image):"
        local output
        output=$(docker images "$image" --format "  {{.Tag}}\t{{.CreatedAt}}\t{{.Size}}" 2>/dev/null || true)
        if [ -n "$output" ]; then
            echo "$output"
        else
            echo "  No images found"
        fi
    done
    echo ""
}

show_history() {
    local service="$1"

    if [ -z "$service" ]; then
        print_error "Please specify a service"
        exit 1
    fi

    local image
    image="$(image_name "$service")"

    echo ""
    echo "Version history for $service ($image):"
    echo "=============================="
    docker images "$image" --format "{{.Tag}}\t{{.ID}}\t{{.CreatedAt}}" | head -10
    echo ""
}

tag_version() {
    local service="$1"
    local tag="$2"
    
    if [ -z "$service" ] || [ -z "$tag" ]; then
        print_error "Please specify service and tag"
        echo "Usage: $0 tag <service> <tag>"
        exit 1
    fi
    
    local image
    image="$(image_name "$service")"

    # Check if image exists
    if ! docker images "$image:latest" --format "{{.ID}}" | grep -q .; then
        print_error "Image $image:latest not found"
        print_info "Build it first (./scripts/deploy.sh ... --build) or check the compose project name"
        exit 1
    fi
    
    print_info "Tagging $image:latest as $image:$tag..."
    docker tag "$image:latest" "$image:$tag"
    print_success "Tagged $image:$tag"
}

rollback_service() {
    local service="$1"
    local tag="$2"
    
    if [ -z "$service" ] || [ -z "$tag" ]; then
        print_error "Please specify service and tag"
        echo "Usage: $0 rollback <service> <tag>"
        exit 1
    fi
    
    local image
    image="$(image_name "$service")"
    local container="trackhub-${service}"

    # Check if tagged image exists
    if ! docker images "$image:$tag" --format "{{.ID}}" | grep -q .; then
        print_error "Image $image:$tag not found"
        echo "Available tags:"
        docker images "$image" --format "  {{.Tag}}"
        exit 1
    fi
    
    print_warning "Rolling back $service to version $tag"
    read -p "Continue? (y/N) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        print_info "Rollback cancelled"
        exit 0
    fi
    
    # Tag current as rollback point
    local timestamp=$(date +%Y%m%d_%H%M%S)
    print_info "Saving current version as $image:pre-rollback-$timestamp..."
    docker tag "$image:latest" "$image:pre-rollback-$timestamp" 2>/dev/null || true
    
    # Tag the rollback version as latest
    print_info "Setting $image:$tag as latest..."
    docker tag "$image:$tag" "$image:latest"
    
    # Restart the container
    print_info "Restarting $container..."
    cd "$PROJECT_DIR"
    docker compose stop "$service" 2>/dev/null || true
    docker compose rm -f "$service" 2>/dev/null || true
    docker compose up -d --force-recreate --no-build --no-deps "$service"
    
    print_success "Rolled back $service to $tag"
    
    # Show current status
    echo ""
    docker compose ps "$service"
}

# Main
case "${1:-}" in
    list)
        list_images
        ;;
    history)
        show_history "$2"
        ;;
    tag)
        tag_version "$2" "$3"
        ;;
    rollback)
        rollback_service "$2" "$3"
        ;;
    *)
        usage
        exit 1
        ;;
esac
