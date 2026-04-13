#!/usr/bin/env bash
set -euo pipefail
# Display detection library — sourced by firstboot.sh, setup.sh, and display-detect.sh
#
# Checks whether an HDMI display is physically connected to the Pi.
# On Pi 4+ with vc4-kms-v3d, /dev/fb0 always exists even without HDMI.
# We must check DRM status files to distinguish connected from disconnected.

has_display() {
    [[ -c /dev/fb0 ]] || return 1

    local found_status=false
    for card in /sys/class/drm/card*-HDMI-*/status; do
        [[ -f "$card" ]] || continue
        found_status=true
        grep -q "^connected" "$card" && return 0
    done

    # DRM status files exist but none say "connected" → headless
    # Explicit check for clarity — avoids executing $found_status as a command
    if [[ "$found_status" == "true" ]]; then
        return 1
    fi

    # No DRM status files at all (very old firmware) → assume display if fb0 exists
    return 0
}
