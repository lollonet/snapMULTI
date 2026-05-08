#!/usr/bin/env bash
# snapmulti-music-bind — restore network music mounts to their natural
# merged-root paths after overlayroot rewrites them.
#
# overlayroot (with the recurse=0 setting we use to avoid ordering cycles)
# is supposed to leave _netdev fstab entries alone. In practice, the
# initramfs script still rewrites them: an NFS line like
#   raspy:/music /media/nfs-music nfs ... _netdev,nofail
# ends up mounted at /media/root-ro/media/nfs-music in the running system,
# AND a non-functional overlay wrap is added at /media/nfs-music whose
# upper/work dirs do not exist, so that overlay mount silently fails
# (nofail). Result: /media/nfs-music is an empty directory, MPD/myMPD
# bind-mount it as /music inside their containers, and the library is
# invisible.
#
# This service-script bridges the gap: bind-mount the lower-layer view
# back to the natural path so MPD sees the actual content.
#
# Usage:
#   snapmulti-music-bind          # bind mounts (idempotent)
#   snapmulti-music-bind --unmount  # release bindings (for ExecStop)

set -euo pipefail

ACTION="${1:-bind}"

bind_one() {
    local lower_path="$1"
    local natural_path="$2"

    [[ -d "$lower_path" ]] || return 0

    if [[ "$ACTION" == "--unmount" ]]; then
        if mountpoint -q "$natural_path"; then
            umount "$natural_path" 2>/dev/null || true
        fi
        return 0
    fi

    # Idempotent: if already a (bind) mountpoint, leave it alone
    if mountpoint -q "$natural_path"; then
        return 0
    fi

    # Sanity-check the lower layer has actual content. An empty source
    # would be a NFS/SMB mount-failure case — binding it would mask a
    # genuine "library missing" warning from boot-tune / device-smoke.
    if ! find "$lower_path" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null | read -r _; then
        echo "snapmulti-music-bind: $lower_path is empty — skipping (mount may have failed)"
        return 0
    fi

    mkdir -p "$natural_path"
    if mount --bind "$lower_path" "$natural_path"; then
        echo "snapmulti-music-bind: bound $lower_path -> $natural_path"
    else
        echo "snapmulti-music-bind: failed to bind $lower_path -> $natural_path" >&2
        return 1
    fi
}

# Network-backed sources where the overlayroot rewrite manifests. USB is
# excluded because it uses UUID-based fstab and the overlayroot script
# treats it differently in practice.
bind_one /media/root-ro/media/nfs-music /media/nfs-music
bind_one /media/root-ro/media/smb-music /media/smb-music

exit 0
