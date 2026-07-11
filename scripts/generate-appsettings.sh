#!/bin/bash
# =============================================================================
# TrackHub AppSettings Generator
# =============================================================================
# Generates appsettings.json files for all services from a central configuration
# Usage: ./generate-appsettings.sh [--output-dir <dir>] [--env-file <file>]
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

# Default values
OUTPUT_DIR=""
ENV_FILE="$PROJECT_DIR/.env"
DEPLOY_TO_SOURCES=false

usage() {
    echo "Usage: $0 [options]"
    echo ""
    echo "Options:"
    echo "  --output-dir <dir>   Output directory for generated files (default: prints to stdout)"
    echo "  --env-file <file>    Environment file to load (default: ../.env)"
    echo "  --deploy-to-sources  Deploy generated files directly to source repositories"
    echo "  --service <name>     Generate only for specific service"
    echo "  --list-services      List available services"
    echo "  --help               Show this help"
    echo ""
    echo "Examples:"
    echo "  $0 --output-dir ./generated"
    echo "  $0 --deploy-to-sources"
    echo "  $0 --service manager --output-dir ./generated"
}

# Parse arguments
SERVICE_FILTER=""
while [[ $# -gt 0 ]]; do
    case $1 in
        --output-dir)
            OUTPUT_DIR="$2"
            shift 2
            ;;
        --env-file)
            ENV_FILE="$2"
            shift 2
            ;;
        --deploy-to-sources)
            DEPLOY_TO_SOURCES=true
            shift
            ;;
        --service)
            SERVICE_FILTER="$2"
            shift 2
            ;;
        --list-services)
            echo "Available services:"
            echo "  authority  - TrackHub.AuthorityServer"
            echo "  security   - TrackHubSecurity"
            echo "  manager    - TrackHub.Manager"
            echo "  router     - TrackHubRouter"
            echo "  geofencing - TrackHub.Geofencing"
            echo "  telemetry  - TrackHub.Telemetry"
            echo "  reporting  - TrackHub.Reporting"
            exit 0
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

# Load environment variables
if [ -f "$ENV_FILE" ]; then
    print_info "Loading environment from: $ENV_FILE"
    set -a
    source "$ENV_FILE"
    set +a
else
    print_warning "Environment file not found: $ENV_FILE"
    print_info "Using system environment variables"
fi

# Set defaults for variables that might not be set
CERTIFICATE_PATH=${CERTIFICATE_PATH:-"/app/certificates/certificate.pfx"}
CERTIFICATE_THUMBPRINT=${CERTIFICATE_THUMBPRINT:-""}
OPENIDDICT_SCOPES=${OPENIDDICT_SCOPES:-"mobile_scope,driver_mobile_scope,web_scope,service_scope"}

# Service to source directory mapping
declare -A SERVICE_PATHS=(
    ["authority"]="TrackHub.AuthorityServer/src/Web"
    ["security"]="TrackHubSecurity/src/Web"
    ["manager"]="TrackHub.Manager/src/Web"
    ["router"]="TrackHubRouter/src/Web"
    ["geofencing"]="TrackHub.Geofencing/src/Web"
    ["telemetry"]="TrackHub.Telemetry/src/Web"
    ["reporting"]="TrackHub.Reporting/src/Web"
)

serilog_section() {
    cat << EOF
  "Serilog": {
    "MinimumLevel": {
      "Default": "Information",
      "Override": {
        "Microsoft": "Warning",
        "Microsoft.Hosting.Lifetime": "Information",
        "System": "Warning"
      }
    },
    "WriteTo": [
      { "Name": "Console" },
      {
        "Name": "PostgreSQL",
        "Args": {
          "connectionString": "Name=Logging",
          "tableName": "logs",
          "needAutoCreateTable": true,
          "batchSizeLimit": 50,
          "period": "00:00:02"
        }
      }
    ]
  }
EOF
}

# Generate appsettings for Authority Server
generate_authority() {
    cat << EOF
{
  "ConnectionStrings": {
    "Security": "${DB_CONNECTION_SECURITY}",
    "Logging": "${DB_CONNECTION_LOGGING}"
  },
$(serilog_section),
  "OpenIddict": {
    "LoadCertFromFile": true,
    "Path": "${CERTIFICATE_PATH}",
    "Password": "${CERTIFICATE_PASSWORD}",
    "Thumbprint": "${CERTIFICATE_THUMBPRINT}",
    "Scopes": "${OPENIDDICT_SCOPES}"
  },
  "AllowedHosts": "*",
  "AllowedCorsOrigins": "${ALLOWED_CORS_ORIGINS}"
}
EOF
}

# Generate appsettings for Security API
generate_security() {
    cat << EOF
{
  "ConnectionStrings": {
    "Security": "${DB_CONNECTION_SECURITY}",
    "Logging": "${DB_CONNECTION_LOGGING}"
  },
$(serilog_section),
  "AuthorityServer": {
    "Authority": "${AUTHORITY_URL}",
    "ValidateAudience": true,
    "ValidateIssuer": true,
    "ValidateIssuerSigningKey": true,
    "ClientId": "${SECURITY_CLIENT_ID}",
    "ClientSecret": "${SECURITY_CLIENT_SECRET}",
    "Scope": "service_scope"
  },
  "OpenIddict": {
    "LoadCertFromFile": true,
    "Path": "${CERTIFICATE_PATH}",
    "Password": "${CERTIFICATE_PASSWORD}",
    "Thumbprint": "${CERTIFICATE_THUMBPRINT}"
  },
  "AppSettings": {
    "GraphQLManagerService": "${GRAPHQL_MANAGER_SERVICE}",
    "EncryptionKey": "${ENCRYPTION_KEY}"
  },
  "AllowedHosts": "*",
  "AllowedCorsOrigins": "${ALLOWED_CORS_ORIGINS}"
}
EOF
}

# Generate appsettings for Manager API
generate_manager() {
    cat << EOF
{
  "ConnectionStrings": {
    "DefaultConnection": "${DB_CONNECTION_MANAGER}",
    "Logging": "${DB_CONNECTION_LOGGING}"
  },
$(serilog_section),
  "AuthorityServer": {
    "Authority": "${AUTHORITY_URL}",
    "ValidateAudience": true,
    "ValidateIssuer": true,
    "ValidateIssuerSigningKey": true
  },
  "AppSettings": {
    "GraphQLIdentityService": "${GRAPHQL_IDENTITY_SERVICE}",
    "GraphQLSecurityService": "${GRAPHQL_SECURITY_SERVICE}",
    "GraphQLRouterService": "${GRAPHQL_ROUTER_SERVICE}",
    "EncryptionKey": "${ENCRYPTION_KEY}"
  },
  "DocumentStorage": {
    "Provider": "${DOCUMENT_STORAGE_PROVIDER:-LocalFileSystem}",
    "LocalRootPath": "${DOCUMENT_STORAGE_LOCAL_ROOT:-/app/documents}",
    "RetentionDays": ${DOCUMENT_RETENTION_DAYS:-1825}
  },
  "OpenIddict": {
    "LoadCertFromFile": true,
    "Path": "${CERTIFICATE_PATH}",
    "Password": "${CERTIFICATE_PASSWORD}",
    "Thumbprint": "${CERTIFICATE_THUMBPRINT}"
  },
  "AllowedHosts": "*",
  "AllowedCorsOrigins": "${ALLOWED_CORS_ORIGINS}"
}
EOF
}

# Generate appsettings for Router API
generate_router() {
    cat << EOF
{
  "ConnectionStrings": {
    "Logging": "${DB_CONNECTION_LOGGING}"
  },
$(serilog_section),
  "AuthorityServer": {
    "Authority": "${AUTHORITY_URL}",
    "ValidateAudience": true,
    "ValidateIssuer": true,
    "ValidateIssuerSigningKey": true,
    "ClientId": "${ROUTER_CLIENT_ID}",
    "ClientSecret": "${ROUTER_CLIENT_SECRET}",
    "Scope": "service_scope"
  },
  "AppSettings": {
    "GraphQLIdentityService": "${GRAPHQL_IDENTITY_SERVICE}",
    "GraphQLManagerService": "${GRAPHQL_MANAGER_SERVICE}",
    "GraphQLTelemetryService": "${GRAPHQL_TELEMETRY_SERVICE}",
    "GraphQLGeofenceService": "${GRAPHQL_GEOFENCE_SERVICE}",
    "EncryptionKey": "${ENCRYPTION_KEY}",
    "Protocols": [
      "CommandTrack",
      "Flespi",
      "GeoTab",
      "GpsGate",
      "Navixy",
      "Samsara",
      "Traccar",
      "Wialon"
    ]
  },
  "OpenIddict": {
    "LoadCertFromFile": true,
    "Path": "${CERTIFICATE_PATH}",
    "Password": "${CERTIFICATE_PASSWORD}",
    "Thumbprint": "${CERTIFICATE_THUMBPRINT}"
  },
  "AllowedHosts": "*",
  "AllowedCorsOrigins": "${ALLOWED_CORS_ORIGINS}"
}
EOF
}

# Generate appsettings for Geofencing API
generate_geofencing() {
    cat << EOF
{
  "ConnectionStrings": {
    "DefaultConnection": "${DB_CONNECTION_MANAGER}",
    "Logging": "${DB_CONNECTION_LOGGING}"
  },
$(serilog_section),
  "AuthorityServer": {
    "Authority": "${AUTHORITY_URL}",
    "ValidateAudience": true,
    "ValidateIssuer": true,
    "ValidateIssuerSigningKey": true
  },
  "AppSettings": {
    "GraphQLIdentityService": "${GRAPHQL_IDENTITY_SERVICE}"
  },
  "OpenIddict": {
    "LoadCertFromFile": true,
    "Path": "${CERTIFICATE_PATH}",
    "Password": "${CERTIFICATE_PASSWORD}",
    "Thumbprint": "${CERTIFICATE_THUMBPRINT}"
  },
  "AllowedHosts": "*",
  "AllowedCorsOrigins": "${ALLOWED_CORS_ORIGINS}"
}
EOF
}

# Generate appsettings for Reporting API
generate_reporting() {
    cat << EOF
{
  "ConnectionStrings": {
    "Logging": "${DB_CONNECTION_LOGGING}"
  },
$(serilog_section),
  "AuthorityServer": {
    "Authority": "${AUTHORITY_URL}",
    "ValidateAudience": true,
    "ValidateIssuer": true,
    "ValidateIssuerSigningKey": true
  },
  "AppSettings": {
    "GraphQLIdentityService": "${GRAPHQL_IDENTITY_SERVICE}",
    "GraphQLRouterService": "${GRAPHQL_ROUTER_SERVICE}",
    "GraphQLGeofenceService": "${GRAPHQL_GEOFENCE_SERVICE}",
    "GraphQLManagerService": "${GRAPHQL_MANAGER_SERVICE}",
    "GraphQLTelemetryService": "${GRAPHQL_TELEMETRY_SERVICE}"
  },
  "OpenIddict": {
    "LoadCertFromFile": true,
    "Path": "${CERTIFICATE_PATH}",
    "Password": "${CERTIFICATE_PASSWORD}",
    "Thumbprint": "${CERTIFICATE_THUMBPRINT}"
  },
  "AllowedHosts": "*",
  "AllowedCorsOrigins": "${ALLOWED_CORS_ORIGINS}"
}
EOF
}

# Generate appsettings for Telemetry API
generate_telemetry() {
    cat << EOF
{
  "ConnectionStrings": {
    "DefaultConnection": "${DB_CONNECTION_TELEMETRY}",
    "Logging": "${DB_CONNECTION_LOGGING}"
  },
$(serilog_section),
  "AuthorityServer": {
    "Authority": "${AUTHORITY_URL}",
    "ValidateAudience": true,
    "ValidateIssuer": true,
    "ValidateIssuerSigningKey": true
  },
  "AppSettings": {
    "GraphQLIdentityService": "${GRAPHQL_IDENTITY_SERVICE}"
  },
  "OpenIddict": {
    "LoadCertFromFile": true,
    "Path": "${CERTIFICATE_PATH}",
    "Password": "${CERTIFICATE_PASSWORD}",
    "Thumbprint": "${CERTIFICATE_THUMBPRINT}"
  },
  "AllowedHosts": "*",
  "AllowedCorsOrigins": "${ALLOWED_CORS_ORIGINS}"
}
EOF
}

# Generate and output/save appsettings for a service
process_service() {
    local service=$1
    local content=""
    
    case $service in
        authority)  content=$(generate_authority) ;;
        security)   content=$(generate_security) ;;
        manager)    content=$(generate_manager) ;;
        router)     content=$(generate_router) ;;
        geofencing) content=$(generate_geofencing) ;;
        telemetry)  content=$(generate_telemetry) ;;
        reporting)  content=$(generate_reporting) ;;
        *)
            print_error "Unknown service: $service"
            return 1
            ;;
    esac
    
    if [ "$DEPLOY_TO_SOURCES" = true ]; then
        local target_dir="$PROJECT_DIR/../${SERVICE_PATHS[$service]}"
        if [ -d "$target_dir" ]; then
            echo "$content" > "$target_dir/appsettings.json"
            print_success "Generated: $target_dir/appsettings.json"
        else
            print_warning "Directory not found: $target_dir"
        fi
    elif [ -n "$OUTPUT_DIR" ]; then
        mkdir -p "$OUTPUT_DIR"
        echo "$content" > "$OUTPUT_DIR/appsettings.$service.json"
        print_success "Generated: $OUTPUT_DIR/appsettings.$service.json"
    else
        echo "# =============================================="
        echo "# $service - appsettings.json"
        echo "# =============================================="
        echo "$content"
        echo ""
    fi
}

# Main execution
print_info "TrackHub AppSettings Generator"
echo ""

SERVICES=("authority" "security" "manager" "router" "geofencing" "telemetry" "reporting")

if [ -n "$SERVICE_FILTER" ]; then
    process_service "$SERVICE_FILTER"
else
    for service in "${SERVICES[@]}"; do
        process_service "$service"
    done
fi

if [ "$DEPLOY_TO_SOURCES" = true ] || [ -n "$OUTPUT_DIR" ]; then
    echo ""
    print_success "AppSettings generation complete!"
fi
