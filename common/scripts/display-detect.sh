#!/usr/bin/env bash
# Detect HDMI at boot and reconcile Docker Compose visual containers.
# Installed as systemd oneshot by setup.sh.
set -euo pipefail

INSTALL_DIR="${SNAPCLIENT_DIR:-/opt/snapclient}"
ENV_FILE="$INSTALL_DIR/.env"

# shellcheck source=display.sh
source "$INSTALL_DIR/scripts/display.sh"

# Wait for Docker daemon to be fully ready (socket listening)
for i in {1..30}; do
    if docker info &>/dev/null; then
        break
    fi
    echo "Waiting for Docker daemon... ($i/30)"
    sleep 1
done

if ! docker info &>/dev/null; then
    echo "ERROR: Docker daemon not ready after 30s, skipping display reconciliation"
    exit 1
fi

# Detect display
if has_display; then
    PROFILE="framebuffer"
    echo "Display detected -- starting visual stack"
else
    PROFILE=""
    echo "No display -- headless mode (audio only)"
fi

# Check if profile actually changed (avoid unnecessary container restarts)
current_profile=""
if [[ -f "$ENV_FILE" ]]; then
    current_profile=$(grep "^COMPOSE_PROFILES=" "$ENV_FILE" 2>/dev/null | cut -d= -f2 || true)
fi

if [[ "$current_profile" == "$PROFILE" ]]; then
    echo "COMPOSE_PROFILES unchanged ($PROFILE) -- no restart needed"
    exit 0
fi

# Update COMPOSE_PROFILES in .env (idempotent)
if grep -q '^COMPOSE_PROFILES=' "$ENV_FILE" 2>/dev/null; then
    sed -i "s|^COMPOSE_PROFILES=.*|COMPOSE_PROFILES=$PROFILE|" "$ENV_FILE"
else
    echo "COMPOSE_PROFILES=$PROFILE" >> "$ENV_FILE"
fi

# Reconcile running containers with new profile
cd "$INSTALL_DIR"
# Note: docker compose implicitly reads .env from working directory ($INSTALL_DIR)
# Keep this cd before the compose invocation or move the .env reference
echo "Reconciling containers (COMPOSE_PROFILES=$PROFILE)..."
docker compose up -d --remove-orphans
