#!/usr/bin/env bash
# Entrypoint for shairport-sync container
# Sanitizes DEVICE_NAME to prevent command injection

set -euo pipefail

# Source shared utilities
# shellcheck source=common/sanitize.sh
source "$(dirname "$0")/common/sanitize.sh"

# Build device name
if [ -n "$DEVICE_NAME" ]; then
    # User provided name - sanitize it
    SAFE_NAME=$(sanitize_airplay_name "$DEVICE_NAME")
else
    # Default: hostname + " AirPlay"
    SAFE_NAME="$(hostname) AirPlay"
fi

# Ensure name is not empty after sanitization
if [ -z "$SAFE_NAME" ]; then
    SAFE_NAME="snapMULTI AirPlay"
fi

# -M enables metadata output (cover art controlled by config file)
exec shairport-sync -c /etc/shairport-sync.conf -M -a "$SAFE_NAME"
