#!/usr/bin/env bash
# Adapted from GioF71's tidal-connect wrapper for FIFO output
# Used with edgecrush3r/tidal-connect image
set -euo pipefail

# Source shared utilities (mounted at /common/sanitize.sh in container)
# shellcheck source=../common/sanitize.sh
source /common/sanitize.sh

if ! mkdir -p /config; then
    echo "ERROR: Cannot create /config directory" >&2
    exit 1
fi

source /common.sh
configure

PLAYBACK_DEVICE=$(get_playback_device)
echo "PLAYBACK_DEVICE=[$PLAYBACK_DEVICE]"

# Speaker controller disabled - was causing duplicate device registration
# If audio quality issues occur, re-enable this block
#if [ -f /usr/bin/tmux ] && [ -f /app/ifi-tidal-release/bin/speaker_controller_application ]; then
#    echo "Starting Speaker Controller in background..."
#    if ! /usr/bin/tmux new-session -d -s speaker_controller_application '/app/ifi-tidal-release/bin/speaker_controller_application'; then
#        echo "WARNING: Failed to start speaker controller. Audio quality may be affected." >&2
#    fi
#    sleep "${SLEEP_TIME_SEC:-3}"
#fi

friendly_name_raw=$(load_key_value "$KEY_FRIENDLY_NAME")
friendly_name=$(sanitize_device_name "$friendly_name_raw")
model_name_raw=$(load_key_value "$KEY_MODEL_NAME")
model_name=$(sanitize_device_name "$model_name_raw")
mqa_codec=$(load_key_value "$KEY_MQA_CODEC")
mqa_passthrough=$(load_key_value "$KEY_MQA_PASSTHROUGH")

echo "Starting TIDAL Connect: $friendly_name"

while true; do
    echo "Starting TIDAL Connect..."
    /app/ifi-tidal-release/bin/tidal_connect_application \
        --tc-certificate-path /app/ifi-tidal-release/id_certificate/IfiAudio_ZenStream.dat \
        --playback-device "${PLAYBACK_DEVICE}" \
        -f "${friendly_name}" \
        --model-name "${model_name}" \
        --codec-mpegh true \
        --codec-mqa "${mqa_codec}" \
        --disable-app-security false \
        --disable-web-security true \
        --enable-mqa-passthrough "${mqa_passthrough}" \
        --log-level "${LOG_LEVEL:-3}" \
        --enable-websocket-log 0 \
        --websocket-port 8888
    echo "TIDAL Connect stopped."
    [ "${RESTART_ON_FAIL:-1}" -eq 1 ] || break
    echo "Restarting in ${RESTART_WAIT_SEC:-10} seconds..."
    sleep "${RESTART_WAIT_SEC:-10}"
done
