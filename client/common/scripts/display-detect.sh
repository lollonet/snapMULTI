#!/usr/bin/env bash
# Detect HDMI at boot and set COMPOSE_PROFILES in .env.
# Does NOT start/stop containers — snapclient.service owns the lifecycle.
# Installed as systemd oneshot by setup.sh (runs Before=snapclient.service).
set -euo pipefail

INSTALL_DIR="${SNAPCLIENT_DIR:-/opt/snapclient}"
ENV_FILE="$INSTALL_DIR/.env"

# shellcheck source=display.sh
source "$INSTALL_DIR/scripts/display.sh"

# Detect display
if has_display; then
    PROFILE="framebuffer"
    echo "Display detected — visual stack will be started"
else
    PROFILE=""
    echo "No display — headless mode (audio only)"
fi

# Check if profile actually changed
current_profile=""
if [[ -f "$ENV_FILE" ]]; then
    current_profile=$(grep "^COMPOSE_PROFILES=" "$ENV_FILE" 2>/dev/null | cut -d= -f2 || true)
fi

if [[ "$current_profile" == "$PROFILE" ]]; then
    echo "COMPOSE_PROFILES unchanged ($PROFILE) — no action needed"
    exit 0
fi

# Update COMPOSE_PROFILES in .env (idempotent)
if grep -q '^COMPOSE_PROFILES=' "$ENV_FILE" 2>/dev/null; then
    sed -i "s|^COMPOSE_PROFILES=.*|COMPOSE_PROFILES=$PROFILE|" "$ENV_FILE"
else
    echo "COMPOSE_PROFILES=$PROFILE" >> "$ENV_FILE"
fi
echo "COMPOSE_PROFILES updated to '$PROFILE'"

# If containers are already running (not first boot), restart via systemd
if systemctl is-active --quiet snapclient.service 2>/dev/null; then
    echo "Restarting client stack via systemd..."
    systemctl restart snapclient.service
fi
