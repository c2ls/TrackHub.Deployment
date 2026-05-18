#!/bin/bash
# =============================================================================
# TrackHub Configuration Sync Script
# =============================================================================
# Synchronizes configuration across all services and the React frontend
# This is a wrapper that handles both appsettings.json and .env updates
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

usage() {
    echo "Usage: $0 <command> [options]"
    echo ""
    echo "Commands:"
    echo "  generate     Generate appsettings.json for all backend services"
    echo "  deploy       Generate and deploy to source repositories"
    echo "  frontend     Generate React .env file"
    echo "  validate     Validate current configuration"
    echo "  show         Show current configuration values"
    echo ""
    echo "Options:"
    echo "  --env-file <file>   Environment file to use (default: .env)"
    echo ""
    echo "Examples:"
    echo "  $0 generate"
    echo "  $0 deploy"
    echo "  $0 frontend"
    echo "  $0 validate"
}

# Load environment
load_env() {
    local env_file="${1:-$PROJECT_DIR/.env}"
    if [ -f "$env_file" ]; then
        set -a
        source "$env_file"
        set +a
        return 0
    fi
    return 1
}

# Validate required variables
validate_config() {
    local missing=()
    
    # Required variables
    local required=(
        "DOMAIN"
        "ALLOWED_CORS_ORIGINS"
        "DB_CONNECTION_SECURITY"
        "DB_CONNECTION_MANAGER"
        "DB_CONNECTION_LOGGING"
        "CERTIFICATE_PASSWORD"
        "ENCRYPTION_KEY"
        "AUTHORITY_URL"
    )
    
    for var in "${required[@]}"; do
        if [ -z "${!var}" ]; then
            missing+=("$var")
        fi
    done
    
    if [ ${#missing[@]} -gt 0 ]; then
        print_error "Missing required configuration:"
        for var in "${missing[@]}"; do
            echo "  - $var"
        done
        return 1
    fi
    
    print_success "All required configuration variables are set"
    return 0
}

# Show current configuration
show_config() {
    echo ""
    echo "Current Configuration:"
    echo "======================"
    echo ""
    echo "Domain & CORS:"
    echo "  DOMAIN: ${DOMAIN:-<not set>}"
    echo "  ALLOWED_CORS_ORIGINS: ${ALLOWED_CORS_ORIGINS:-<not set>}"
    echo ""
    echo "Database:"
    echo "  DB_CONNECTION_SECURITY: ${DB_CONNECTION_SECURITY:+***configured***}"
    echo "  DB_CONNECTION_MANAGER: ${DB_CONNECTION_MANAGER:+***configured***}"
    echo "  DB_CONNECTION_LOGGING: ${DB_CONNECTION_LOGGING:+***configured***}"
    echo ""
    echo "Authority & Security:"
    echo "  AUTHORITY_URL: ${AUTHORITY_URL:-<not set>}"
    echo "  CERTIFICATE_PASSWORD: ${CERTIFICATE_PASSWORD:+***configured***}"
    echo "  ENCRYPTION_KEY: ${ENCRYPTION_KEY:+***configured***}"
    echo ""
    echo "Internal Service URLs:"
    echo "  GRAPHQL_IDENTITY_SERVICE: ${GRAPHQL_IDENTITY_SERVICE:-<not set>}"
    echo "  GRAPHQL_SECURITY_SERVICE: ${GRAPHQL_SECURITY_SERVICE:-<not set>}"
    echo "  GRAPHQL_MANAGER_SERVICE: ${GRAPHQL_MANAGER_SERVICE:-<not set>}"
    echo "  GRAPHQL_ROUTER_SERVICE: ${GRAPHQL_ROUTER_SERVICE:-<not set>}"
    echo "  GRAPHQL_GEOFENCE_SERVICE: ${GRAPHQL_GEOFENCE_SERVICE:-<not set>}"
    echo ""
    echo "Frontend (React):"
    echo "  REACT_APP_CLIENT_ID: ${REACT_APP_CLIENT_ID:-<not set>}"
    echo "  REACT_APP_AUTHORIZATION_ENDPOINT: ${REACT_APP_AUTHORIZATION_ENDPOINT:-<not set>}"
    echo ""
}

# Generate React .env file
generate_frontend_env() {
    local output_file="${1:-$PROJECT_DIR/../TrackHub/.env}"
    
    cat > "$output_file" << EOF
GENERATE_SOURCEMAP=false
REACT_APP_DEFAULT_LAT=${REACT_APP_DEFAULT_LAT:-4.624335}
REACT_APP_DEFAULT_LNG=${REACT_APP_DEFAULT_LNG:--74.063644}
REACT_APP_CLIENT_ID=${REACT_APP_CLIENT_ID:-web_client}
REACT_APP_AUTHORIZATION_ENDPOINT=${REACT_APP_AUTHORIZATION_ENDPOINT}
REACT_APP_TOKEN_ENDPOINT=${REACT_APP_TOKEN_ENDPOINT}
REACT_APP_CALLBACK_ENDPOINT=${REACT_APP_CALLBACK_ENDPOINT}
REACT_APP_REVOKE_TOKEN_ENDPOINT=${REACT_APP_REVOKE_TOKEN_ENDPOINT}
REACT_APP_LOGOUT_ENDPOINT=${REACT_APP_LOGOUT_ENDPOINT}
REACT_APP_MANAGER_ENDPOINT=${REACT_APP_MANAGER_ENDPOINT}
REACT_APP_ROUTER_ENDPOINT=${REACT_APP_ROUTER_ENDPOINT}
REACT_APP_SECURITY_ENDPOINT=${REACT_APP_SECURITY_ENDPOINT}
REACT_APP_GEOFENCING_ENDPOINT=${REACT_APP_GEOFENCING_ENDPOINT}
REACT_APP_REPORTING_ENDPOINT=${REACT_APP_REPORTING_ENDPOINT}
EOF
    
    print_success "Generated: $output_file"
}

# Main execution
ENV_FILE="$PROJECT_DIR/.env"

# Parse global options
while [[ $# -gt 0 ]]; do
    case $1 in
        --env-file)
            ENV_FILE="$2"
            shift 2
            ;;
        generate|deploy|frontend|validate|show)
            COMMAND="$1"
            shift
            break
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            COMMAND="$1"
            shift
            break
            ;;
    esac
done

# Load environment
if ! load_env "$ENV_FILE"; then
    print_warning "Could not load environment file: $ENV_FILE"
fi

case $COMMAND in
    generate)
        print_info "Generating appsettings.json files..."
        "$SCRIPT_DIR/generate-appsettings.sh" --output-dir "$PROJECT_DIR/generated" --env-file "$ENV_FILE"
        ;;
    deploy)
        print_info "Deploying configuration to source repositories..."
        if validate_config; then
            "$SCRIPT_DIR/generate-appsettings.sh" --deploy-to-sources --env-file "$ENV_FILE"
            generate_frontend_env
        else
            print_error "Configuration validation failed. Fix errors before deploying."
            exit 1
        fi
        ;;
    frontend)
        print_info "Generating React .env file..."
        generate_frontend_env
        ;;
    validate)
        validate_config
        ;;
    show)
        show_config
        ;;
    *)
        print_error "Unknown command: $COMMAND"
        usage
        exit 1
        ;;
esac
