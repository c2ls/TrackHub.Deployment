#!/bin/bash
# =============================================================================
# Source repository configuration
# =============================================================================
# Shared by clone-repos.sh and deploy.sh. Reads GITHUB_* settings from .env so
# a private deployment only has to change that untracked file.
#
# Usage:  source "$SCRIPT_DIR/repo-config.sh"
#         repo_url TrackHubCommon          -> clone URL, credentials included
#         repo_url_clean TrackHubCommon    -> same URL without credentials
#         "${TRACKHUB_REPOS[@]}"           -> every repository the stack needs
# =============================================================================

# Repositories that make up the stack. Names are the public ones; the owner and
# suffix configured below are applied on top.
TRACKHUB_REPOS=(
    "TrackHub"
    "TrackHub.AuthorityServer"
    "TrackHubSecurity"
    "TrackHub.Manager"
    "TrackHubRouter"
    "TrackHub.Geofencing"
    "TrackHub.Telemetry"
    "TrackHub.Reporting"
    "TrackHubCommon"
)

# Load GITHUB_* settings from .env when present.
_repo_config_load() {
    local env_file="$1"
    [ -f "$env_file" ] || return 0
    local key
    for key in GITHUB_OWNER GITHUB_REPO_SUFFIX GITHUB_BRANCH GITHUB_USER GITHUB_PASSWORD; do
        # Only take the value from .env if it is not already set in the environment.
        if [ -z "${!key}" ]; then
            local value
            value="$(grep -E "^${key}=" "$env_file" | tail -1 | cut -d= -f2- | sed 's/^"//; s/"$//')"
            [ -n "$value" ] && export "$key=$value"
        fi
    done
}

_repo_config_load "${PROJECT_DIR:-$(dirname "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)")}/.env"

# Defaults keep the public deployment working with no configuration at all.
GITHUB_OWNER="${GITHUB_OWNER:-shernandezp}"
GITHUB_REPO_SUFFIX="${GITHUB_REPO_SUFFIX:-}"
GITHUB_BRANCH="${GITHUB_BRANCH:-master}"

# Full repository name, suffix applied (TrackHubCommon -> TrackHubCommon.Commercial)
repo_name() {
    echo "${1}${GITHUB_REPO_SUFFIX}"
}

# Clone URL without credentials — safe to store as a git remote.
repo_url_clean() {
    echo "https://github.com/${GITHUB_OWNER}/$(repo_name "$1").git"
}

# Clone URL with credentials when they are configured. Only ever passed to git
# on the command line, never written into .git/config.
repo_url() {
    if [ -n "$GITHUB_USER" ] && [ -n "$GITHUB_PASSWORD" ]; then
        echo "https://${GITHUB_USER}:${GITHUB_PASSWORD}@github.com/${GITHUB_OWNER}/$(repo_name "$1").git"
    else
        repo_url_clean "$1"
    fi
}

# Clone if missing, otherwise fast-forward. Credentials stay out of the remote.
repo_clone_or_update() {
    local repo="$1" target="$2"
    if [ -d "$target/.git" ]; then
        git -C "$target" pull --ff-only "$(repo_url "$repo")" "$GITHUB_BRANCH"
    else
        git clone --branch "$GITHUB_BRANCH" "$(repo_url "$repo")" "$target"
        git -C "$target" remote set-url origin "$(repo_url_clean "$repo")"
    fi
}
