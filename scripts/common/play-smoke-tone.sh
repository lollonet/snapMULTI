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
# Suppression rules (always honoured; never interrupt music or annoy):
#   1. TEST_TONE=false in install.conf → silent
#   2. SNAPMULTI_BOOT_SMOKE_TONES=off in .env → silent (multi-room opt-out)
#   3. Snapcast has an active stream playing → silent (don't talk over music)
#   4. aplay missing or no default ALSA device → silent
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

# TEST_TONE=false in install.conf (same flag that controls the install-time
# 1 s test tone) silences us too.
for conf in /opt/snapmulti/install.conf /opt/snapclient/install.conf /boot/firmware/snapmulti/install.conf; do
    if [[ -f "$conf" ]]; then
        val=$(grep -m1 '^TEST_TONE=' "$conf" 2>/dev/null | cut -d= -f2- | tr -d '\r[:space:]' || true)
        if [[ "$val" == "false" ]]; then exit 0; fi
        break
    fi
done

# Per-deployment opt-out for multi-room setups.
for env_file in /opt/snapmulti/.env /opt/snapclient/.env; do
    if [[ -f "$env_file" ]]; then
        val=$(grep -m1 '^SNAPMULTI_BOOT_SMOKE_TONES=' "$env_file" 2>/dev/null | cut -d= -f2- | tr -d '\r[:space:]' || true)
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
