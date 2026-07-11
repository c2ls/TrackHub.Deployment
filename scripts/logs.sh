#!/bin/bash
# =============================================================================
# TrackHub Log Viewer Script
# =============================================================================
# View logs from services
# Usage: ./logs.sh [service_name] [options]
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

usage() {
    echo "Usage: $0 [service_name] [options]"
    echo ""
    echo "Services:"
    echo "  all        - All services (default)"
    echo "  nginx      - Nginx reverse proxy"
    echo "  frontend   - React frontend"
    echo "  authority  - Authority Server"
    echo "  security   - Security API"
    echo "  manager    - Manager API"
    echo "  router     - Router API"
    echo "  geofencing - Geofencing API"
    echo "  telemetry  - Telemetry API"
    echo "  reporting  - Reporting API"
    echo "  syncworker - SyncWorker background service"
    echo ""
    echo "Options:"
    echo "  -f, --follow  - Follow log output (default)"
    echo "  -n, --lines   - Number of lines to show (default: 100)"
    echo "  --no-follow   - Don't follow, just show last lines"
    echo ""
    echo "Examples:"
    echo "  $0                    # All services, follow mode"
    echo "  $0 manager            # Manager service, follow mode"
    echo "  $0 security -n 50     # Security service, last 50 lines, follow"
    echo "  $0 nginx --no-follow  # Nginx, last 100 lines, no follow"
}

SERVICE="all"
FOLLOW="-f"
LINES="100"
COMPOSE_FILE="docker-compose.yml"

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        all|nginx|frontend|authority|security|manager|router|geofencing|telemetry|reporting|syncworker)
            SERVICE="$1"
            shift
            ;;
        -f|--follow)
            FOLLOW="-f"
            shift
            ;;
        --no-follow)
            FOLLOW=""
            shift
            ;;
        -n|--lines)
            LINES="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            usage
            exit 1
            ;;
    esac
done

cd "$PROJECT_DIR"

if [ "$SERVICE" == "all" ]; then
    docker compose -f "$COMPOSE_FILE" logs --tail="$LINES" $FOLLOW
else
    docker compose -f "$COMPOSE_FILE" logs --tail="$LINES" $FOLLOW "$SERVICE"
fi
