#!/bin/bash
# =============================================================================
# TrackHub Deployment Script
# =============================================================================
# Main deployment script for TrackHub application stack
# Usage: ./deploy.sh [full|frontend|backend] [--build|--pull] [--no-cache]
# Builds use Docker layer caching by default and reliably detect source changes.
# Containers are always force recreated so updated images are deployed.
# =============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Default values
DEPLOYMENT_TYPE="full"
BUILD_TYPE="--build"
SKIP_INIT=false
NO_CACHE=false

print_header() {
    echo -e "${BLUE}"
    echo "=============================================="
    echo "  TrackHub Deployment Script"
    echo "=============================================="
    echo -e "${NC}"
}

print_success() {
    echo -e "${GREEN}✓ $1${NC}"
}

print_warning() {
    echo -e "${YELLOW}⚠ $1${NC}"
}

print_error() {
    echo -e "${RED}✗ $1${NC}"
}

print_info() {
    echo -e "${BLUE}ℹ $1${NC}"
}

usage() {
    echo "Usage: $0 [deployment_type] [options]"
    echo ""
    echo "Deployment Types:"
    echo "  full      - Deploy frontend and all backend services (default)"
    echo "  frontend  - Deploy only the frontend"
    echo "  backend   - Deploy only the backend services"
    echo ""
    echo "Options:"
    echo "  --build     - Build images locally using Docker layer cache (default)"
    echo "  --pull      - Pull images from registry"
    echo "  --no-cache  - Force a full rebuild ignoring the Docker layer cache"
    echo "                (rarely needed; normal builds already detect source changes)"
    echo "  --skip-init - Skip database initialization (for migrations)"
    echo "  --help      - Show this help message"
    echo ""
    echo "Examples:"
    echo "  $0 full --build"
    echo "  $0 frontend"
    echo "  $0 backend --build"
    echo "  $0 full --build --skip-init  # For migrating to new server"
}

check_prerequisites() {
    print_info "Checking prerequisites..."
    
    # Check Docker
    if ! command -v docker &> /dev/null; then
        print_error "Docker is not installed. Please install Docker first."
        exit 1
    fi
    print_success "Docker is installed"
    
    # Check Docker Compose
    if ! docker compose version &> /dev/null; then
        print_error "Docker Compose is not available. Please install Docker Compose."
        exit 1
    fi
    print_success "Docker Compose is available"
    
    # Check if Docker daemon is running
    if ! docker info &> /dev/null; then
        print_error "Docker daemon is not running. Please start Docker."
        exit 1
    fi
    print_success "Docker daemon is running"
}

check_configuration() {
    print_info "Checking configuration files..."
    
    # Check .env file
    if [ ! -f "$PROJECT_DIR/.env" ]; then
        print_error ".env file not found!"
        print_info "Copy .env.example to .env and configure it:"
        print_info "  cp .env.example .env"
        print_info "  nano .env"
        exit 1
    fi
    print_success ".env file exists"
    
    # Check certificates
    if [ ! -f "$PROJECT_DIR/certificates/certificate.pfx" ]; then
        print_warning "OpenIddict certificate not found at certificates/certificate.pfx"
        print_info "Please place your certificate file before starting services"
    else
        print_success "OpenIddict certificate found"
    fi
    
    # Check SSL certificates
    if [ ! -f "$PROJECT_DIR/certificates/fullchain.pem" ] || [ ! -f "$PROJECT_DIR/certificates/privkey.pem" ]; then
        print_warning "SSL certificates not found"
        print_info "Please place fullchain.pem and privkey.pem in the certificates folder"
    else
        print_success "SSL certificates found"
    fi
    
    # Check clients.json for database initialization
    if [ ! -f "$PROJECT_DIR/config/clients.json" ]; then
        print_warning "clients.json not found at config/clients.json"
        print_info "Copy config/clients.json.example to config/clients.json and configure it"
    else
        print_success "clients.json found"
    fi
}

select_compose_file() {
    case $DEPLOYMENT_TYPE in
        "full")
            COMPOSE_FILE="$PROJECT_DIR/docker-compose.yml"
            ;;
        "frontend")
            COMPOSE_FILE="$PROJECT_DIR/docker-compose.frontend.yml"
            ;;
        "backend")
            COMPOSE_FILE="$PROJECT_DIR/docker-compose.backend.yml"
            ;;
        *)
            print_error "Invalid deployment type: $DEPLOYMENT_TYPE"
            usage
            exit 1
            ;;
    esac
    
    if [ ! -f "$COMPOSE_FILE" ]; then
        print_error "Compose file not found: $COMPOSE_FILE"
        exit 1
    fi
    
    print_info "Using compose file: $COMPOSE_FILE"
}

deploy() {
    print_info "Starting deployment..."
    
    cd "$PROJECT_DIR"
    
    # Stop existing containers
    print_info "Stopping existing containers..."
    docker compose -f "$COMPOSE_FILE" down --remove-orphans || true
    
    # Build or pull images
    if [ "$BUILD_TYPE" == "--build" ]; then
        if [ "$NO_CACHE" = true ]; then
            print_info "Building images without Docker layer cache (--no-cache)..."
            docker compose -f "$COMPOSE_FILE" build --no-cache
        else
            print_info "Building images (layer cache detects source changes)..."
            docker compose -f "$COMPOSE_FILE" build
        fi
    else
        print_info "Pulling images..."
        docker compose -f "$COMPOSE_FILE" pull
    fi
    
    # Start services
    if [ "$SKIP_INIT" = true ]; then
        print_warning "Skipping database initialization (--skip-init flag set)"
        print_info "Starting services without db-init..."
        # Start all services except db-init
        docker compose -f "$COMPOSE_FILE" up -d --force-recreate --no-build --no-deps nginx frontend authority security manager router geofencing telemetry reporting syncworker 2>/dev/null || \
        docker compose -f "$COMPOSE_FILE" up -d --force-recreate --no-build --no-deps nginx frontend authority security manager router geofencing telemetry reporting 2>/dev/null || \
        docker compose -f "$COMPOSE_FILE" up -d --force-recreate --no-build
    else
        print_info "Starting all services..."
        docker compose -f "$COMPOSE_FILE" up -d --force-recreate --no-build
    fi
    
    print_success "Deployment complete!"
}

show_status() {
    print_info "Service Status:"
    echo ""
    docker compose -f "$COMPOSE_FILE" ps
    echo ""
    print_info "To view logs, run:"
    echo "  docker compose -f $COMPOSE_FILE logs -f"
    echo ""
    print_info "To check health endpoints:"
    echo "  curl -k https://localhost/health"
    echo "  curl -k https://localhost/health/authority"
    echo "  curl -k https://localhost/health/security"
    echo "  curl -k https://localhost/health/manager"
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        full|frontend|backend)
            DEPLOYMENT_TYPE="$1"
            shift
            ;;
        --build|--pull)
            BUILD_TYPE="$1"
            shift
            ;;
        --no-cache)
            NO_CACHE=true
            shift
            ;;
        --skip-init)
            SKIP_INIT=true
            shift
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            print_error "Unknown option: $1"
            usage
            exit 1
            ;;
    esac
done

# Main execution
print_header
check_prerequisites
check_configuration
select_compose_file
deploy
show_status
