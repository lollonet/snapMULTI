#!/usr/bin/env bash
# Mount music library source (NFS/SMB/USB) and scrub credentials.
#
# Expects from caller:
#   MUSIC_SOURCE — streaming|usb|nfs|smb|manual
#   NFS_SERVER, NFS_EXPORT — for NFS mounts
#   SMB_SERVER, SMB_SHARE, SMB_USER, SMB_PASS — for SMB mounts
#   SNAP_BOOT — boot partition path (for credential scrubbing)
#
# Exports:
#   MUSIC_PATH — path to mounted music library
#   SKIP_MUSIC_SCAN — set to 1 for streaming-only mode
#
# Usage:
#   source scripts/common/mount-music.sh
#   setup_music_source
#   scrub_credentials

# shellcheck disable=SC2034
LOG_SOURCE="music"

# Source unified logger
if ! declare -F log_info &>/dev/null; then
    # shellcheck source=unified-log.sh
    source "$(dirname "${BASH_SOURCE[0]}")/unified-log.sh" 2>/dev/null || {
        log_info()  { echo "[INFO] [music] $*"; }
        log_warn()  { echo "[WARN] [music] $*" >&2; }
        log_error() { echo "[ERROR] [music] $*" >&2; }
    }
fi

setup_music_source() {
    case "${MUSIC_SOURCE:-}" in
        streaming)
            mkdir -p /media/music
            export MUSIC_PATH="/media/music"
            export SKIP_MUSIC_SCAN=1
            log_info "Streaming-only mode — no local music library"
            ;;
        usb)
            local usb_dev="" usb_mount="/media/usb-music"
            local dev
            for dev in /dev/sd?1 /dev/sd?; do
                [[ -b "$dev" ]] || continue
                blkid "$dev" &>/dev/null && { usb_dev="$dev"; break; }
            done
            if [[ -n "$usb_dev" ]]; then
                mkdir -p "$usb_mount"
                log_info "Mounting USB: $usb_dev → $usb_mount"
                if mount "$usb_dev" "$usb_mount" -o ro; then
                    if ! grep -qF "$usb_dev" /etc/fstab; then
                        echo "$usb_dev $usb_mount auto ro,nofail 0 0" >> /etc/fstab
                    fi
                    export MUSIC_PATH="$usb_mount"
                    log_info "USB mounted: $usb_dev at $usb_mount"
                else
                    log_warn "Failed to mount $usb_dev — deploy.sh will try auto-detect"
                fi
            else
                log_warn "No USB drive found — plug in before powering on"
            fi
            ;;
        nfs)
            local mount_point="/media/nfs-music"
            mkdir -p "$mount_point"
            log_info "Mounting NFS: ${NFS_SERVER:-}:${NFS_EXPORT:-}"
            if mount -t nfs "${NFS_SERVER}:${NFS_EXPORT}" "$mount_point" -o ro,soft,timeo=50,rsize=32768,_netdev; then
                if ! grep -qF "${NFS_SERVER}:${NFS_EXPORT}" /etc/fstab; then
                    echo "${NFS_SERVER}:${NFS_EXPORT} $mount_point nfs ro,soft,timeo=50,rsize=32768,_netdev,nofail 0 0" >> /etc/fstab
                fi
                export MUSIC_PATH="$mount_point"
                log_info "NFS mounted: $mount_point"
            else
                log_warn "NFS mount failed — falling back to auto-detect"
            fi
            ;;
        smb)
            local mount_point="/media/smb-music"
            local creds_file="/etc/snapmulti-smb-credentials"
            mkdir -p "$mount_point"
            log_info "Mounting SMB: //${SMB_SERVER:-}/${SMB_SHARE:-}"

            local mount_opts="ro,_netdev,iocharset=utf8"
            if [[ -n "${SMB_USER:-}" ]]; then
                printf 'username=%s\npassword=%s\n' "$SMB_USER" "$SMB_PASS" > "$creds_file"
                chmod 600 "$creds_file"
                mount_opts="${mount_opts},credentials=$creds_file"
            else
                mount_opts="${mount_opts},guest"
            fi

            if timeout 60 mount -t cifs "//${SMB_SERVER}/${SMB_SHARE}" "$mount_point" -o "$mount_opts"; then
                if ! grep -qF "//${SMB_SERVER}/${SMB_SHARE}" /etc/fstab; then
                    echo "//${SMB_SERVER}/${SMB_SHARE} $mount_point cifs ${mount_opts},nofail 0 0" >> /etc/fstab
                fi
                export MUSIC_PATH="$mount_point"
                log_info "SMB mounted: $mount_point"
            else
                log_warn "SMB mount failed — falling back to auto-detect"
            fi
            ;;
        manual|"")
            # No-op: deploy.sh auto-detect fallback
            ;;
    esac
}

# Scrub credentials from boot partition (FAT32 has no file permissions)
scrub_credentials() {
    local conf="${SNAP_BOOT:-}/install.conf"
    [[ -f "$conf" ]] || return 0

    local scrub_failed=false field
    for field in SMB_PASS SMB_USER SMB_SERVER SMB_SHARE NFS_SERVER NFS_EXPORT; do
        sed -i "s/^${field}=.*/${field}=/" "$conf" 2>/dev/null \
            || scrub_failed=true
    done
    if [[ "$scrub_failed" == "true" ]]; then
        log_warn "Could not scrub credentials via sed — removing install.conf"
        rm -f "$conf" 2>/dev/null || true
    else
        log_info "Credentials scrubbed from install.conf"
    fi
}
