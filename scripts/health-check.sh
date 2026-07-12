#!/bin/bash
# =============================================================================
# TrackHub Health Check Script
# =============================================================================
# Check the health status of all services in the given compose file.
#
# Usage: ./health-check.sh [domain] [protocol] [compose_file]
#        (defaults: localhost https docker-compose.yml)
#
# Only the services declared in the compose file are probed, so a backend-only or
# frontend-only server does not report the services it never deploys as missing.
# Exit code: 0 when every checked component is healthy, 1 otherwise (all checks run,
# the script never aborts on the first failure) - safe to use as a deploy/CI gate.
# =============================================================================

# NOTE: no "set -e" - a failing check must not abort the report.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Defaults
DOMAIN=${1:-"localhost"}
PROTOCOL=${2:-"https"}
COMPOSE_FILE=${3:-"docker-compose.yml"}

# Number of failed checks (script exit code depends on it)
FAILURES=0

# -----------------------------------------------------------------------------
# Which services does this deployment actually run?
# -----------------------------------------------------------------------------
# Read them from the compose file in use so that e.g. "frontend" is not reported as
# missing on a backend-only server. If the list cannot be read (docker unavailable),
# fall back to checking everything.
DEPLOYED_SERVICES=""

load_deployed_services() {
    local file="$COMPOSE_FILE"
    [ -f "$file" ] || file="$PROJECT_DIR/$COMPOSE_FILE"
    if [ ! -f "$file" ]; then
        echo -e "${YELLOW}⚠ Compose file not found: $COMPOSE_FILE - checking all services${NC}"
        return
    fi
    DEPLOYED_SERVICES=$( (cd "$PROJECT_DIR" && docker compose -f "$file" config --services 2>/dev/null) | tr '\n' ' ')
    if [ -z "$DEPLOYED_SERVICES" ]; then
        echo -e "${YELLOW}⚠ Could not read services from $COMPOSE_FILE - checking all services${NC}"
    fi
}

is_deployed() {
    local service=$1
    [ -z "$DEPLOYED_SERVICES" ] && return 0    # unknown -> check it
    case " $DEPLOYED_SERVICES " in
        *" $service "*) return 0 ;;
        *) return 1 ;;
    esac
}

# Records the result of a check (0 = ok) so the script can exit non-zero at the end.
record() {
    [ "$1" -ne 0 ] && FAILURES=$((FAILURES + 1))
    return 0
}

print_header() {
    echo -e "${BLUE}"
    echo "=============================================="
    echo "  TrackHub Health Check"
    echo "=============================================="
    echo -e "${NC}"
}

check_endpoint() {
    local name=$1
    local url=$2
    
    printf "%-20s" "$name:"
    
    response=$(curl -sk -o /dev/null -w "%{http_code}" "$url" 2>/dev/null || echo "000")
    
    if [ "$response" == "200" ]; then
        echo -e "${GREEN}✓ Healthy (HTTP $response)${NC}"
        return 0
    elif [ "$response" == "000" ]; then
        echo -e "${RED}✗ Connection Failed${NC}"
        return 1
    else
        echo -e "${YELLOW}⚠ HTTP $response${NC}"
        return 1
    fi
}

check_container() {
    local name=$1

    printf "%-20s" "$name:"

    # Containers with a healthcheck report .State.Health.Status; containers
    # without one (e.g. syncworker) have no Health object at all, so fall back to
    # the run state and report "running"/"exited"/... instead of "not found".
    local format='{{if .State.Health}}{{.State.Health.Status}}{{else}}{{if .State.Running}}running{{else}}{{.State.Status}}{{end}}{{end}}'
    status=$(docker inspect --format="$format" "trackhub-$name" 2>/dev/null || echo "not found")
    [ -z "$status" ] && status="not found"

    case $status in
        "healthy")
            echo -e "${GREEN}✓ Healthy${NC}"
            return 0
            ;;
        "running")
            echo -e "${GREEN}✓ Running (no healthcheck)${NC}"
            return 0
            ;;
        "unhealthy")
            echo -e "${RED}✗ Unhealthy${NC}"
            return 1
            ;;
        "starting")
            echo -e "${YELLOW}⚠ Starting...${NC}"
            return 1
            ;;
        "not found")
            echo -e "${RED}✗ Container not found${NC}"
            return 1
            ;;
        *)
            echo -e "${RED}✗ Not running (status: $status)${NC}"
            return 1
            ;;
    esac
}

# Check a container only when the compose file declares it
check_service_container() {
    local service=$1
    if ! is_deployed "$service"; then
        printf "%-20s" "$service:"
        echo -e "${BLUE}- Not in $(basename "$COMPOSE_FILE") (skipped)${NC}"
        return 0
    fi
    check_container "$service"
    record $?
}

# Check an HTTP endpoint only when its backing service is deployed
check_service_endpoint() {
    local service=$1
    local name=$2
    local url=$3
    if ! is_deployed "$service"; then
        printf "%-20s" "$name:"
        echo -e "${BLUE}- Not in $(basename "$COMPOSE_FILE") (skipped)${NC}"
        return 0
    fi
    check_endpoint "$name" "$url"
    record $?
}

print_header

echo "Domain: $DOMAIN"
echo "Protocol: $PROTOCOL"
echo "Compose file: $COMPOSE_FILE"
echo ""

load_deployed_services

echo "Container Health Status:"
echo "------------------------"
check_service_container "nginx"
check_service_container "authority"
check_service_container "security"
check_service_container "manager"
check_service_container "router"
check_service_container "geofencing"
check_service_container "telemetry"
check_service_container "reporting"
check_service_container "syncworker"
check_service_container "frontend"

echo ""
echo "HTTP Health Endpoints:"
echo "----------------------"
check_service_endpoint "nginx"      "Nginx"      "$PROTOCOL://$DOMAIN/health"
check_service_endpoint "authority"  "Authority"  "$PROTOCOL://$DOMAIN/health/authority"
check_service_endpoint "security"   "Security"   "$PROTOCOL://$DOMAIN/health/security"
check_service_endpoint "manager"    "Manager"    "$PROTOCOL://$DOMAIN/health/manager"
check_service_endpoint "router"     "Router"     "$PROTOCOL://$DOMAIN/health/router"
check_service_endpoint "geofencing" "Geofencing" "$PROTOCOL://$DOMAIN/health/geofencing"
check_service_endpoint "telemetry"  "Telemetry"  "$PROTOCOL://$DOMAIN/health/telemetry"
check_service_endpoint "reporting"  "Reporting"  "$PROTOCOL://$DOMAIN/health/reporting"

echo ""
echo "GraphQL Endpoints:"
echo "------------------"
check_service_endpoint "security"   "Security GraphQL"  "$PROTOCOL://$DOMAIN/Security/graphql/"
check_service_endpoint "manager"    "Manager GraphQL"   "$PROTOCOL://$DOMAIN/Manager/graphql/"
check_service_endpoint "router"     "Router GraphQL"    "$PROTOCOL://$DOMAIN/Router/graphql/"
check_service_endpoint "geofencing" "Geofence GraphQL"  "$PROTOCOL://$DOMAIN/Geofence/graphql/"
check_service_endpoint "telemetry"  "Telemetry GraphQL" "$PROTOCOL://$DOMAIN/Telemetry/graphql/"

echo ""
if [ "$FAILURES" -eq 0 ]; then
    echo -e "${GREEN}✓ Health check complete: all checks passed.${NC}"
    exit 0
fi

echo -e "${RED}✗ Health check complete: $FAILURES check(s) failed.${NC}"
exit 1
