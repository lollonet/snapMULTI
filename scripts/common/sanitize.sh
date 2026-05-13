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
# Truncates to RFC 1123 max (253 chars total)
# Usage: sanitize_hostname "nas.local"
sanitize_hostname() {
    local cleaned
    cleaned=$(printf '%s' "$1" | tr -cd 'A-Za-z0-9.-' | sed 's/^[.-]*//;s/[.-]*$//')
    cleaned="${cleaned:0:253}"
    printf '%s' "$cleaned"
}

# Semantic alias for NFS server validation
sanitize_nfs_server() {
    sanitize_hostname "$1"
}

# Sanitize NFS export path: alphanumeric, forward slash, dots, underscores, hyphens
# Must start with /. Returns empty string if input doesn't start with /.
# Spaces are NOT silently stripped: a path like "/volume1/Music Share" used to
# become "/volume1/MusicShare" and the mount would then fail with a confusing
# ENOENT, leaving the user thinking it was a network/permissions issue when
# the script itself had corrupted the path. Now we emit an explicit error and
# return empty so the caller fails fast at the source.
# Usage: sanitize_nfs_export "/volume1/music"
sanitize_nfs_export() {
    local input="$1"
    if [[ "$input" == *' '* ]]; then
        echo "ERROR: NFS export contains spaces: '$input'" >&2
        echo "ERROR: snapMULTI does not support spaces in NFS paths." >&2
        echo "ERROR: Rename the share on the NAS (e.g. 'Music_Share') and retry." >&2
        return 1
    fi
    local cleaned
    cleaned=$(printf '%s' "$input" | tr -cd 'A-Za-z0-9/._-')
    # Must start with /
    if [[ "$cleaned" == /* ]]; then
        printf '%s' "$cleaned"
    fi
}

# Sanitize SMB share name: alphanumeric, dots, underscores, hyphens.
# Same loud-fail policy as sanitize_nfs_export: spaces become an error
# instead of a silent strip, because Synology / QNAP "Music Share" is a
# real-world case and silent corruption masks the actual problem.
# Usage: sanitize_smb_share "Music"
sanitize_smb_share() {
    local input="$1"
    if [[ "$input" == *' '* ]]; then
        echo "ERROR: SMB share name contains spaces: '$input'" >&2
        echo "ERROR: snapMULTI does not support spaces in SMB share names." >&2
        echo "ERROR: Rename the share on the NAS (e.g. 'Music_Share') and retry." >&2
        return 1
    fi
    printf '%s' "$input" | tr -cd 'A-Za-z0-9._-'
}

# Sanitize SMB username: alphanumeric, dots, underscores, hyphens, @
# Usage: sanitize_smb_user "user@domain"
sanitize_smb_user() {
    printf '%s' "$1" | tr -cd 'A-Za-z0-9._@-'
}
