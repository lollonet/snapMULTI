#!/bin/bash
# From GioF71/tidal-connect - handles audio device configuration

ASOUND_CONF_FILE=/etc/asound.conf
USER_CONFIG_DIR=/userconfig

KEY_PLAYBACK_DEVICE=playback_device
KEY_FORCE_PLAYBACK_DEVICE=force_playback_device
KEY_FRIENDLY_NAME=friendly_name
KEY_MODEL_NAME=model_name
KEY_MQA_CODEC=mqa_codec
KEY_MQA_PASSTHROUGH=mqa_passthrough

save_key_value() { echo "${2}" > /config/$1; }
load_key_value() { [ -f /config/$1 ] && cat /config/$1; }
save_playback_device() { save_key_value $KEY_PLAYBACK_DEVICE $1; }
get_playback_device() { load_key_value $KEY_PLAYBACK_DEVICE; }

set_defaults() {
    save_key_value $KEY_FRIENDLY_NAME "${FRIENDLY_NAME:-Tidal connect}"
    save_key_value $KEY_MODEL_NAME "${MODEL_NAME:-Audio Streamer}"
    save_key_value $KEY_MQA_CODEC "${MQA_CODEC:-false}"
    save_key_value $KEY_MQA_PASSTHROUGH "${MQA_PASSTHROUGH:-false}"
    save_playback_device default
    [ -n "${FORCE_PLAYBACK_DEVICE}" ] && save_key_value $KEY_FORCE_PLAYBACK_DEVICE $FORCE_PLAYBACK_DEVICE
}

check_provided_asound() {
    if [ -f "$USER_CONFIG_DIR/asound.conf" ]; then
        echo "Copying $USER_CONFIG_DIR/asound.conf to $ASOUND_CONF_FILE"
        cp $USER_CONFIG_DIR/asound.conf $ASOUND_CONF_FILE
        [ -z "$(load_key_value $KEY_FORCE_PLAYBACK_DEVICE)" ] && save_key_value $KEY_FORCE_PLAYBACK_DEVICE default
    fi
}

enforce_playback_device_if_requested() {
    local fpd=$(load_key_value $KEY_FORCE_PLAYBACK_DEVICE)
    [ -n "$fpd" ] && save_playback_device $fpd
}

configure() {
    set_defaults
    check_provided_asound
    enforce_playback_device_if_requested
}
