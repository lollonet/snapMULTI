#!/usr/bin/env bash
# play-smoke-tone.sh — emit an audible cue for a smoke/health result.
#
# Usage: play-smoke-tone.sh <pass|warn|fail|skip>
#
# Designed for headless server installs where the operator never sees
# console output: the audio appliance itself reports its health via the
# attached DAC.
#
# Tone vocabulary (matches WAVs in /usr/share/snapmulti/audio/):
#   pass — ascending C5 → E5 → G5 (~450 ms)
#   warn — alternating A4 ↔ C5, 2 cycles (~800 ms)
#   fail — descending tritone A4 → D♯4, 2 cycles (~1.2 s)
#   skip — single 220 Hz chirp (~100 ms)
#
# Suppression rules:
#   1. TEST_TONE=false in install.conf → silent (always honoured)
#   2. SNAPMULTI_BOOT_SMOKE_TONES=off in .env → silent (always honoured, multi-room opt-out)
#   3. Snapcast has an active stream playing → silent (bypassed when SNAPMULTI_FORCE_TONE=1)
#   4. aplay missing or no default ALSA device → silent (always honoured)
#
# Always exits 0. Never blocks the caller.

set -uo pipefail

RESULT="${1:-skip}"
AUDIO_DIR="/usr/share/snapmulti/audio"
WAV="$AUDIO_DIR/smoke-${RESULT}.wav"

case "$RESULT" in
    pass|warn|fail|skip) ;;
    *) exit 0 ;;
esac

[[ -f "$WAV" ]] || exit 0
command -v aplay >/dev/null 2>&1 || exit 0

# Source the env_get helper for the .env opt-out read below. The path
# resolves relative to this script — when deployed under /usr/local/sbin
# (server) or /opt/snapclient/scripts/common (client), the sibling
# common/env-reader.sh is staged alongside. Fallback inline read keeps
# the script functional on stripped bundles without the helper.
_PST_SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "$_PST_SELF/env-reader.sh" ]]; then
    # shellcheck source=common/env-reader.sh
    source "$_PST_SELF/env-reader.sh"
fi

# TEST_TONE=false in install.conf (same flag that controls the install-time
# 1 s test tone) silences us too. install.conf has its own helper
# (install_conf_get); this script does NOT depend on it because
# install-conf-reader.sh is not always staged with play-smoke-tone.sh.
for conf in /opt/snapmulti/install.conf /opt/snapclient/install.conf /boot/firmware/snapmulti/install.conf; do
    if [[ -f "$conf" ]]; then
        val=$(grep -m1 '^TEST_TONE=' "$conf" 2>/dev/null | cut -d= -f2- | tr -d '\r[:space:]' || true)
        if [[ "$val" == "false" ]]; then exit 0; fi
        break
    fi
done

# Per-deployment opt-out for multi-room setups. Uses env_get when the
# helper is loaded; falls back to the legacy inline grep+cut+tr form so
# legacy/stripped bundles still honour the opt-out.
for env_file in /opt/snapmulti/.env /opt/snapclient/.env; do
    if [[ -f "$env_file" ]]; then
        if declare -F env_get >/dev/null 2>&1; then
            val=$(env_get SNAPMULTI_BOOT_SMOKE_TONES "$env_file" all)
        else
            val=$(grep -m1 '^SNAPMULTI_BOOT_SMOKE_TONES=' "$env_file" 2>/dev/null | cut -d= -f2- | tr -d '\r[:space:]' || true)
        fi
        if [[ "$val" == "off" ]]; then exit 0; fi
        break
    fi
done

# Don't interrupt active music — UNLESS SNAPMULTI_FORCE_TONE=1 (auto-boot-smoke sets this so post-reboot status reaches the user even when autoplay resumed).
if [[ "${SNAPMULTI_FORCE_TONE:-0}" != "1" ]] && command -v curl >/dev/null 2>&1; then
    streams_state=$(curl -s --max-time 2 \
        -d '{"id":1,"jsonrpc":"2.0","method":"Server.GetStatus"}' \
        http://localhost:1780/jsonrpc 2>/dev/null || true)
    if printf '%s' "$streams_state" | grep -q '"status":"playing"'; then
        exit 0
    fi
fi

# Best-effort playback. Errors logged to journal only.
if ! aplay -q "$WAV" 2>/dev/null; then
    logger -t snapmulti-smoke-tone -p info \
        "smoke-tone playback failed (result=$RESULT, wav=$WAV)" 2>/dev/null || true
fi

exit 0
