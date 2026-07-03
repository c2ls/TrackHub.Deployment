#!/bin/sh
# =============================================================================
# TrackHub Frontend Entrypoint
# =============================================================================
# The frontend build output is baked into the image at /app/dist. Nginx serves
# the static files from the shared "trackhub-frontend" named volume mounted at
# /app/build.
#
# Docker only copies image content into a named volume the first time the volume
# is created (while it is empty). On every subsequent deployment the volume keeps
# the previous build, so rebuilding the image alone would NOT refresh the files
# nginx serves. To guarantee deterministic updates, this entrypoint refreshes the
# volume with the current image's build output on every container start.
# =============================================================================
set -e

TARGET_DIR="/app/build"
SOURCE_DIR="/app/dist"

echo "[frontend] Refreshing static assets in ${TARGET_DIR} from image build ${SOURCE_DIR}..."

# Remove the readiness marker first so nginx (which waits for a healthy frontend)
# never serves a half-copied set of files.
rm -f "${TARGET_DIR}/.ready" 2>/dev/null || true

# Clear previous contents (including dotfiles) and copy the current build.
find "${TARGET_DIR}" -mindepth 1 -delete 2>/dev/null || true
cp -a "${SOURCE_DIR}/." "${TARGET_DIR}/"

# Mark the copy complete so the container healthcheck reports healthy.
touch "${TARGET_DIR}/.ready"

echo "[frontend] Static assets refreshed successfully."

# Keep the container alive so the volume stays mounted for nginx.
exec tail -f /dev/null
