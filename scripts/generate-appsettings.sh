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
            echo "  syncworker - TrackHubRouter (SyncWorker)"
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
# Audience the APIs validate access tokens against (matches every service appsettings.json)
VALID_AUDIENCE=${VALID_AUDIENCE:-"trackhub_api"}

# Master template (some sections, e.g. syncworker, are sourced from it directly)
TEMPLATE_FILE="$PROJECT_DIR/config/appsettings.template.json"

# Service to source directory mapping
declare -A SERVICE_PATHS=(
    ["authority"]="TrackHub.AuthorityServer/src/Web"
    ["security"]="TrackHubSecurity/src/Web"
    ["manager"]="TrackHub.Manager/src/Web"
    ["router"]="TrackHubRouter/src/Web"
    ["geofencing"]="TrackHub.Geofencing/src/Web"
    ["telemetry"]="TrackHub.Telemetry/src/Web"
    ["reporting"]="TrackHub.Reporting/src/Web"
    ["syncworker"]="TrackHubRouter/src/SyncWorker"
)

# Serilog + Columns blocks, kept in sync with config/appsettings.template.json.
# The PostgreSQL sink resolves "connectionString" as a connection string NAME
# ("Logging"), and needs the "Using" directive plus the top-level "Columns" block.
serilog_section() {
    cat << EOF
  "Serilog": {
    "Using": [
      "Serilog.Sinks.PostgreSQL.Configuration"
    ],
    "MinimumLevel": {
      "Default": "Information",
      "Override": {
        "Microsoft": "Warning",
        "Microsoft.AspNetCore": "Warning",
        "Microsoft.Hosting.Lifetime": "Information",
        "System": "Warning"
      }
    },
    "WriteTo": [
      { "Name": "Console" },
      {
        "Name": "PostgreSQL",
        "Args": {
          "connectionString": "Logging",
          "tableName": "logs",
          "needAutoCreateTable": true,
          "batchSizeLimit": 50,
          "period": "00:00:02"
        }
      }
    ]
  },
  "Columns": {
    "message": "RenderedMessageColumnWriter",
    "message_template": "MessageTemplateColumnWriter",
    "level": {
      "Name": "LevelColumnWriter",
      "Args": {
        "renderAsText": true,
        "dbType": "Varchar"
      }
    },
    "raise_date": "TimestampColumnWriter",
    "exception": "ExceptionColumnWriter",
    "properties": "LogEventSerializedColumnWriter",
    "machine_name": {
      "Name": "SinglePropertyColumnWriter",
      "Args": {
        "propertyName": "MachineName",
        "writeMethod": "Raw"
      }
    },
    "application": {
      "Name": "SinglePropertyColumnWriter",
      "Args": {
        "propertyName": "Application",
        "writeMethod": "Raw"
      }
    },
    "environment_name": {
      "Name": "SinglePropertyColumnWriter",
      "Args": {
        "propertyName": "EnvironmentName",
        "writeMethod": "Raw"
      }
    }
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
    "ValidAudience": "${VALID_AUDIENCE}",
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
    "ValidAudience": "${VALID_AUDIENCE}",
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
    "ValidAudience": "${VALID_AUDIENCE}",
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
    "ValidAudience": "${VALID_AUDIENCE}",
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
    "ValidAudience": "${VALID_AUDIENCE}",
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
    "ValidAudience": "${VALID_AUDIENCE}",
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

# -----------------------------------------------------------------------------
# Template-driven generation
# -----------------------------------------------------------------------------
# Renders "common" merged with "services.<name>" from config/appsettings.template.json
# and expands the ${VAR} placeholders from the environment. Requires jq + envsubst;
# callers must provide a fallback when this returns non-zero.
template_service() {
    local service=$1

    [ -f "$TEMPLATE_FILE" ] || return 1
    command -v jq &> /dev/null || return 1
    command -v envsubst &> /dev/null || return 1

    local section
    section=$(jq -r --arg s "$service" '.services[$s] // empty' "$TEMPLATE_FILE" 2>/dev/null) || return 1
    [ -n "$section" ] || return 1

    jq --arg s "$service" '.common * .services[$s]' "$TEMPLATE_FILE" | envsubst
}

# Generate appsettings for the SyncWorker background service
generate_syncworker() {
    local rendered
    if rendered=$(template_service syncworker) && [ -n "$rendered" ]; then
        printf '%s\n' "$rendered"
        return 0
    fi

    print_warning "No 'syncworker' section in $TEMPLATE_FILE (or jq/envsubst missing); using built-in defaults" >&2

    cat << EOF
{
  "ConnectionStrings": {
    "Logging": "${DB_CONNECTION_LOGGING}"
  },
$(serilog_section),
  "AuthorityServer": {
    "Authority": "${AUTHORITY_URL}",
    "ClientId": "${SYNCWORKER_CLIENT_ID}",
    "ClientSecret": "${SYNCWORKER_CLIENT_SECRET}",
    "IsService": true,
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
  }
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
        syncworker) content=$(generate_syncworker) ;;
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

SERVICES=("authority" "security" "manager" "router" "geofencing" "telemetry" "reporting" "syncworker")

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
