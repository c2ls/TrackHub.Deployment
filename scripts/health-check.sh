#!/bin/bash
# =============================================================================
# TrackHub Health Check Script
# =============================================================================
# Check the health status of all services
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

# Default domain
DOMAIN=${1:-"localhost"}
PROTOCOL=${2:-"https"}

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

print_header

echo "Domain: $DOMAIN"
echo "Protocol: $PROTOCOL"
echo ""

echo "Container Health Status:"
echo "------------------------"
check_container "nginx" || true
check_container "authority" || true
check_container "security" || true
check_container "manager" || true
check_container "router" || true
check_container "geofencing" || true
check_container "telemetry" || true
check_container "reporting" || true
check_container "syncworker" || true
check_container "frontend" || true

echo ""
echo "HTTP Health Endpoints:"
echo "----------------------"
check_endpoint "Nginx" "$PROTOCOL://$DOMAIN/health" || true
check_endpoint "Authority" "$PROTOCOL://$DOMAIN/health/authority" || true
check_endpoint "Security" "$PROTOCOL://$DOMAIN/health/security" || true
check_endpoint "Manager" "$PROTOCOL://$DOMAIN/health/manager" || true
check_endpoint "Router" "$PROTOCOL://$DOMAIN/health/router" || true
check_endpoint "Geofencing" "$PROTOCOL://$DOMAIN/health/geofencing" || true
check_endpoint "Telemetry" "$PROTOCOL://$DOMAIN/health/telemetry" || true
check_endpoint "Reporting" "$PROTOCOL://$DOMAIN/health/reporting" || true

echo ""
echo "GraphQL Endpoints:"
echo "------------------"
check_endpoint "Security GraphQL" "$PROTOCOL://$DOMAIN/Security/graphql/" || true
check_endpoint "Manager GraphQL" "$PROTOCOL://$DOMAIN/Manager/graphql/" || true
check_endpoint "Router GraphQL" "$PROTOCOL://$DOMAIN/Router/graphql/" || true
check_endpoint "Geofence GraphQL" "$PROTOCOL://$DOMAIN/Geofence/graphql/" || true
check_endpoint "Telemetry GraphQL" "$PROTOCOL://$DOMAIN/Telemetry/graphql/" || true

echo ""
echo -e "${BLUE}Health check complete.${NC}"
