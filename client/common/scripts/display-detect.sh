#!/usr/bin/env bash
# Detect HDMI at boot and set COMPOSE_PROFILES in .env.
# Does NOT start/stop containers — snapclient.service owns the lifecycle.
# Installed as systemd oneshot by setup.sh (runs Before=snapclient.service).
set -euo pipefail

INSTALL_DIR="${SNAPCLIENT_DIR:-/opt/snapclient}"
ENV_FILE="$INSTALL_DIR/.env"
ASOUND_CONF="${SNAPCLIENT_ASOUND_CONF:-/etc/asound.conf}"

# shellcheck source=display.sh
source "$INSTALL_DIR/scripts/display.sh"

# The visual stack needs the audio path that setup.sh only builds when a
# display is present at install time: snd-aloop in modules-load.d and an
# /etc/asound.conf that fans out to hw:Loopback via multi_out (written
# together in the same setup.sh branch). A headless install has neither,
# so plugging HDMI in later would start audio-visualizer against a
# missing hw:Loopback (restart loop) with fb-display waiting behind it.
_audio_supports_visualizer() {
    grep -q 'hw:Loopback' "$ASOUND_CONF" 2>/dev/null
}

# Detect display
if has_display; then
    if _audio_supports_visualizer; then
        PROFILE="framebuffer"
        echo "Display detected — visual stack will be started"
    else
        PROFILE=""
        echo "WARNING: Display detected, but this client was installed headless:" >&2
        echo "WARNING:   $ASOUND_CONF has no hw:Loopback for the spectrum visualizer." >&2
        echo "WARNING: Keeping headless mode (audio only). To enable the display, re-run" >&2
        echo "WARNING:   setup.sh with the display connected (sudo ro-mode disable + reboot first" >&2
        echo "WARNING:   if read-only mode is on), or reflash." >&2
    fi
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
