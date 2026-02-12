#!/bin/bash
# Simplified from GioF71/tidal-connect for FIFO output
set -eu

# Sanitize name: remove shell metacharacters, allow only safe chars
# Safe chars: alphanumeric, space, hyphen, underscore, apostrophe, period
sanitize_name() {
    printf '%s' "$1" | tr -cd 'A-Za-z0-9 _-'\''.'
}

mkdir -p /config
source /common.sh
configure

PLAYBACK_DEVICE=$(get_playback_device)
echo "PLAYBACK_DEVICE=[$PLAYBACK_DEVICE]"

# Start speaker controller in background
if [ -f /usr/bin/tmux ] && [ -f /app/ifi-tidal-release/bin/speaker_controller_application ]; then
    echo "Starting Speaker Controller in background..."
    /usr/bin/tmux new-session -d -s speaker_controller_application '/app/ifi-tidal-release/bin/speaker_controller_application'
    sleep ${SLEEP_TIME_SEC:-3}
fi

friendly_name_raw=$(load_key_value $KEY_FRIENDLY_NAME)
friendly_name=$(sanitize_name "$friendly_name_raw")
model_name=$(load_key_value $KEY_MODEL_NAME)
mqa_codec=$(load_key_value $KEY_MQA_CODEC)
mqa_passthrough=$(load_key_value $KEY_MQA_PASSTHROUGH)

COMMAND_LINE="/app/ifi-tidal-release/bin/tidal_connect_application \
    --tc-certificate-path /app/ifi-tidal-release/id_certificate/IfiAudio_ZenStream.dat \
    --playback-device ${PLAYBACK_DEVICE} \
    -f \"${friendly_name}\" \
    --model-name \"${model_name}\" \
    --codec-mpegh true \
    --codec-mqa ${mqa_codec} \
    --disable-app-security false \
    --disable-web-security true \
    --enable-mqa-passthrough ${mqa_passthrough} \
    --log-level ${LOG_LEVEL:-3} \
    --enable-websocket-log 0"

echo "Command: $COMMAND_LINE"

while true; do
    echo "Starting TIDAL Connect..."
    eval "${COMMAND_LINE}"
    echo "TIDAL Connect stopped."
    [ "${RESTART_ON_FAIL:-1}" -eq 1 ] || break
    echo "Restarting in ${RESTART_WAIT_SEC:-10} seconds..."
    sleep ${RESTART_WAIT_SEC:-10}
done
