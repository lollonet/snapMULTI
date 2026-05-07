#!/usr/bin/env bash
set -euo pipefail
# Display detection library — sourced by firstboot.sh, setup.sh, and display-detect.sh
#
# Checks whether ANY display (HDMI, DSI panel, DPI parallel, DisplayPort)
# is physically connected to the Pi. On Pi 4+ with vc4-kms-v3d, /dev/fb0
# always exists even without a monitor — we must check DRM status files.
#
# Connector types we honour:
#   HDMI-*       — standard HDMI (Pi 1-5)
#   DSI-*        — MIPI DSI panels (e.g. official 7" Touch Display, Pi-Top)
#   DPI-*        — parallel DPI panels (some DAC+DSP boards expose video this way)
#   DP-*         — DisplayPort (Pi 5)
#   eDP-*        — embedded DisplayPort (Compute Module carriers)
#
# Connectors we EXCLUDE:
#   *Writeback*  — virtual render target, never represents an actual screen

has_display() {
    [[ -c /dev/fb0 ]] || return 1

    local found_real=false       # at least one supported real-display connector
    local found_any_drm=false    # at least one DRM status file (incl. writeback)
    local card status_path
    for status_path in /sys/class/drm/card*/status; do
        [[ -f "$status_path" ]] || continue
        found_any_drm=true
        card=$(basename "$(dirname "$status_path")")
        # Skip writeback connectors (virtual render target, never a screen)
        [[ "$card" =~ [Ww]riteback ]] && continue
        # Honour only real-display connector types
        case "$card" in
            *-HDMI-*|*-DSI-*|*-DPI-*|*-DP-*|*-eDP-*)
                found_real=true
                grep -q "^connected" "$status_path" && return 0
                ;;
        esac
    done

    # At least one real-display connector exists but none is connected → headless
    if [[ "$found_real" == "true" ]]; then
        return 1
    fi

    # DRM exposes only non-display connectors (e.g. writeback only) → headless
    if [[ "$found_any_drm" == "true" ]]; then
        return 1
    fi

    # No DRM status files at all (very old firmware) → assume display if fb0 exists
    return 0
}
