#!/usr/bin/env bash
# Common sanitization utilities for snapMULTI scripts
# Shared functions to prevent duplication and ensure consistent security

# Sanitize device name: remove shell metacharacters, allow only safe chars
# Safe chars: alphanumeric, space, hyphen, underscore, period
# Note: Apostrophe explicitly excluded to prevent shell injection
# Usage: sanitize_device_name "User Input Name"
sanitize_device_name() {
    printf '%s' "$1" | tr -cd 'A-Za-z0-9 ._-'
}

# Alias for backward compatibility (both use same safe character set)
sanitize_airplay_name() {
    sanitize_device_name "$1"
}

# Sanitize hostname/IP: alphanumeric, dots, hyphens only
# Used for NFS servers, SMB servers, and any network hostname
# Usage: sanitize_hostname "nas.local"
sanitize_hostname() {
    printf '%s' "$1" | tr -cd 'A-Za-z0-9.-' | sed 's/^[.-]*//;s/[.-]*$//'
}

# Alias for backward compatibility
sanitize_nfs_server() {
    sanitize_hostname "$1"
}

# Sanitize NFS export path: alphanumeric, forward slash, dots, underscores, hyphens
# Must start with /. Returns empty string if input doesn't start with /.
# Usage: sanitize_nfs_export "/volume1/music"
sanitize_nfs_export() {
    local cleaned
    cleaned=$(printf '%s' "$1" | tr -cd 'A-Za-z0-9/._-')
    # Must start with /
    if [[ "$cleaned" == /* ]]; then
        printf '%s' "$cleaned"
    fi
}

# Sanitize SMB share name: alphanumeric, dots, underscores, hyphens
# Usage: sanitize_smb_share "Music"
sanitize_smb_share() {
    printf '%s' "$1" | tr -cd 'A-Za-z0-9._-'
}
