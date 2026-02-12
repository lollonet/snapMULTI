#!/usr/bin/env bash
# Common sanitization utilities for snapMULTI scripts
# Shared functions to prevent duplication and ensure consistent security

# Sanitize device name: remove shell metacharacters, allow only safe chars
# Safe chars: alphanumeric, space, hyphen, underscore, period
# Note: Apostrophe explicitly excluded to prevent shell injection
# Usage: sanitize_device_name "User Input Name"
sanitize_device_name() {
    printf '%s' "$1" | tr -cd 'A-Za-z0-9 _-.'
}

# Alias for backward compatibility (both use same safe character set)
sanitize_airplay_name() {
    sanitize_device_name "$1"
}
