#!/bin/bash
# =============================================================================
# TrackHub Source Checkout
# =============================================================================
# Clones (or updates) every repository the stack builds from, into the
# workspace directory alongside TrackHub.Deployment.
# Usage: ./clone-repos.sh
# Configure GITHUB_OWNER / GITHUB_REPO_SUFFIX / GITHUB_BRANCH and, for private
# repositories, GITHUB_USER / GITHUB_PASSWORD in .env
# =============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
WORKSPACE_DIR="$(dirname "$PROJECT_DIR")"

RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

print_success() { echo -e "${GREEN}✓ $1${NC}"; }
print_error()   { echo -e "${RED}✗ $1${NC}"; }
print_info()    { echo -e "${BLUE}ℹ $1${NC}"; }

source "$SCRIPT_DIR/repo-config.sh"

print_info "Source: github.com/${GITHUB_OWNER}/<repo>${GITHUB_REPO_SUFFIX} (branch ${GITHUB_BRANCH})"
print_info "Target: $WORKSPACE_DIR"
if [ -n "$GITHUB_USER" ]; then
    print_info "Authenticating as ${GITHUB_USER}"
fi
echo

failed=()
for repo in "${TRACKHUB_REPOS[@]}"; do
    target="$WORKSPACE_DIR/$repo"
    if [ -d "$target/.git" ]; then
        printf "%-26s updating... " "$repo"
    else
        printf "%-26s cloning...  " "$repo"
    fi

    if repo_clone_or_update "$repo" "$target" >/dev/null 2>&1; then
        echo "ok"
    else
        echo "FAILED"
        failed+=("$repo")
    fi
done

echo
if [ ${#failed[@]} -gt 0 ]; then
    print_error "Failed: ${failed[*]}"
    print_info "For private repositories set GITHUB_USER and GITHUB_PASSWORD in .env."
    print_info "GITHUB_PASSWORD must be a Personal Access Token, not your account password."
    exit 1
fi

print_success "All repositories ready in $WORKSPACE_DIR"
