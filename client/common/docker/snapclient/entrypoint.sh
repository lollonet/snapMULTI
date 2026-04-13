#!/usr/bin/env bash
set -euo pipefail

# Default values (SNAPSERVER_HOST empty = mDNS autodiscovery)
SNAPSERVER_HOST="${SNAPSERVER_HOST:-}"
SNAPSERVER_PORT="${SNAPSERVER_PORT:-1704}"
HOST_ID="${HOST_ID:-snapclient}"
SOUNDCARD="${SOUNDCARD:-default}"
# Ethernet defaults; setup.sh overrides for WiFi (250/8)
ALSA_BUFFER_TIME="${ALSA_BUFFER_TIME:-150}"
ALSA_FRAGMENTS="${ALSA_FRAGMENTS:-4}"
MIXER="${MIXER:-software}"

# Validate string values - reject shell metacharacters
validate_string() {
    case "$1" in
        *[\'\"\\$\`\;\&\|\>\<\(\)\{\}\[\]]*)
            echo "Error: Invalid characters in $2"
            exit 1
            ;;
    esac
}
validate_string "${HOST_ID}" "HOST_ID"
validate_string "${SOUNDCARD}" "SOUNDCARD"
validate_string "${SNAPSERVER_HOST}" "SNAPSERVER_HOST"

# Validate numeric values and enforce sane bounds
case "${ALSA_BUFFER_TIME}" in
    ''|*[!0-9]*) echo "Invalid ALSA_BUFFER_TIME, using default 150"; ALSA_BUFFER_TIME=150 ;;
esac
if [ "${ALSA_BUFFER_TIME}" -lt 50 ] || [ "${ALSA_BUFFER_TIME}" -gt 2000 ]; then
    echo "ALSA_BUFFER_TIME out of range (50-2000), using default 150"
    ALSA_BUFFER_TIME=150
fi

case "${ALSA_FRAGMENTS}" in
    ''|*[!0-9]*) echo "Invalid ALSA_FRAGMENTS, using default 4"; ALSA_FRAGMENTS=4 ;;
esac
if [ "${ALSA_FRAGMENTS}" -lt 2 ] || [ "${ALSA_FRAGMENTS}" -gt 16 ]; then
    echo "ALSA_FRAGMENTS out of range (2-16), using default 4"
    ALSA_FRAGMENTS=4
fi

case "${SNAPSERVER_PORT}" in
    ''|*[!0-9]*) echo "Invalid SNAPSERVER_PORT, using default 1704"; SNAPSERVER_PORT=1704 ;;
esac

# Validate mixer mode (prefix before optional ':' params)
MIXER_MODE="${MIXER%%:*}"
case "${MIXER_MODE}" in
    software|hardware|none) ;;
    *) echo "Invalid MIXER mode '${MIXER_MODE}', using software"; MIXER=software ;;
esac
validate_string "${MIXER}" "MIXER"

echo "Starting snapclient..."
if [ -n "${SNAPSERVER_HOST}" ]; then
    echo "  Server: ${SNAPSERVER_HOST}:${SNAPSERVER_PORT}"
else
    echo "  Server: autodiscovery (mDNS)"
fi
echo "  Host ID: ${HOST_ID}"
echo "  Soundcard: ${SOUNDCARD}"
echo "  Mixer: ${MIXER}"
echo "  ALSA buffer: ${ALSA_BUFFER_TIME}ms, ${ALSA_FRAGMENTS} fragments"

# Build snapclient command with URL format (--host/--port are deprecated)
SNAP_ARGS=(
    --hostID "${HOST_ID}"
    --soundcard "${SOUNDCARD}"
    --mixer "${MIXER}"
    --player "alsa:buffer_time=${ALSA_BUFFER_TIME}:fragments=${ALSA_FRAGMENTS}"
)

if [ -n "${SNAPSERVER_HOST}" ]; then
    exec /usr/bin/snapclient "${SNAP_ARGS[@]}" \
        "tcp://${SNAPSERVER_HOST}:${SNAPSERVER_PORT}" "$@"
else
    exec /usr/bin/snapclient "${SNAP_ARGS[@]}" "$@"
fi
