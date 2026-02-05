#!/bin/sh
# Entrypoint for shairport-sync container
# Sanitizes DEVICE_NAME to prevent command injection

set -eu

# Sanitize DEVICE_NAME: remove shell metacharacters, allow only safe chars
# Safe chars: alphanumeric, space, hyphen, underscore, apostrophe
sanitize_name() {
    # Remove dangerous characters, keep alphanumeric, space, hyphen, underscore, apostrophe
    printf '%s' "$1" | tr -cd 'A-Za-z0-9 _-'\''.'
}

# Build device name
if [ -n "$DEVICE_NAME" ]; then
    # User provided name - sanitize it
    SAFE_NAME=$(sanitize_name "$DEVICE_NAME")
else
    # Default: hostname + " AirPlay"
    SAFE_NAME="$(hostname) AirPlay"
fi

# Ensure name is not empty after sanitization
if [ -z "$SAFE_NAME" ]; then
    SAFE_NAME="snapMULTI AirPlay"
fi

exec shairport-sync -c /etc/shairport-sync.conf -a "$SAFE_NAME"
