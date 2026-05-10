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

# Write a hand-crafted systemd .mount + .automount pair for a network share.
# Unlike /etc/fstab, files in /etc/systemd/system/ are immune to the
# overlayroot initramfs hook that rewrites paths and strips `nofail` — so
# the units survive the first post-overlayroot boot intact and will not
# promote a transient NFS/SMB miss into a `local-fs.target` failure.
#
# The `.automount` companion is what is `WantedBy=multi-user.target`. The
# `.mount` itself is NOT enabled directly — it fires on first access to
# Where=. This matters for the snapMULTI server unit, which lists
# `RequiresMountsFor=` only for the project root and audio FIFO dir, NOT
# for the music library: a lazy automount means snapserver / Spotify /
# AirPlay / Snapcast start even with the NAS unreachable. MPD inside its
# container triggers the mount on its first `find /music ...` scan; if
# the NAS is down the directory stays empty (logged warning, not a unit
# failure). See PR adding automount for community-launch readiness.
#
# Args:
#   $1 — fs type (nfs, cifs)
#   $2 — What= (server:export, //server/share, etc.)
#   $3 — Where= (mount point)
#   $4 — comma-separated mount options (must include `nofail`)
#   $5 — TimeoutSec value (seconds)
_write_systemd_mount_unit() {
    local fstype="$1" what="$2" where="$3" options="$4" timeout="${5:-45}"
    local mount_name automount_name unit_path automount_path

    # systemd-escape ships with systemd — hard-fail, do NOT fall back to fstab (see PR #325).
    if ! command -v systemd-escape &>/dev/null; then
        log_error "systemd-escape unavailable — install with 'apt-get install --reinstall systemd'."
        return 1
    fi

    mount_name="$(systemd-escape -p --suffix=mount "$where")"
    automount_name="$(systemd-escape -p --suffix=automount "$where")"
    unit_path="/etc/systemd/system/${mount_name}"
    automount_path="/etc/systemd/system/${automount_name}"

    cat > "$unit_path" << EOF
[Unit]
Description=Mount music share at ${where} (snapMULTI, overlayroot-safe)
Documentation=man:systemd.mount(5)
After=network-online.target nss-lookup.target
Wants=network-online.target
# No Before= here: with the lazy automount companion, this .mount unit
# fires on first access from inside MPD's container — well after
# snapmulti-server.service / snapclient.service are running. Boot-time
# ordering would have no effect AND mislead future readers about the
# topology.

[Mount]
What=${what}
Where=${where}
Type=${fstype}
Options=${options}
TimeoutSec=${timeout}
EOF
    chmod 644 "$unit_path"

    cat > "$automount_path" << EOF
[Unit]
Description=Automount music share at ${where} (snapMULTI, lazy)
Documentation=man:systemd.automount(5)
# Companion to ${mount_name}. Enabled in [Install]; the .mount itself
# is fired on first access to Where=. This decouples server startup
# from NAS reachability — snapserver / Spotify / AirPlay run regardless
# of whether the music share is currently mountable.
#
# DO NOT add After=network-online.target / Wants=network-online.target
# here. The .automount is a watch on the directory entry — it does not
# itself need the network. Only the .mount unit it triggers needs the
# network ordering, and that's already declared above.
#
# Adding network ordering on the .automount creates a systemd ordering
# cycle (sysinit.target → local-fs.target → this .automount →
# network-online.target → network.target → ... → sysinit.target).
# systemd resolves the cycle by deleting local-fs.target /
# sockets.target / systemd-update-done.service — degrading the first
# post-overlayroot boot in ways that surface as "device came up
# without network" and force the user to power-cycle. Verified
# empirically on snapvideo + snapdigi (2026-05-10 v0.7.0 reflash);
# pi3hat (minimal headless) survived the same cycle by chance.
# Pattern matches systemd-fstab-generator: ordering only on .mount,
# never on .automount.

[Automount]
Where=${where}
TimeoutIdleSec=0

[Install]
WantedBy=multi-user.target
EOF
    chmod 644 "$automount_path"

    # Idempotent enable: ensure the final state is exactly { .automount
    # enabled, .mount NOT enabled }. Earlier versions of this helper
    # called `systemctl enable "$mount_name"` directly, which created
    # a `multi-user.target.wants/<name>.mount` symlink. Without this
    # explicit disable, that symlink would survive `daemon-reload` and
    # the eager .mount would still start at boot in parallel with the
    # new lazy .automount — re-introducing the exact regression this
    # PR fixes (snapserver hanging on a slow NAS). The disable is a
    # no-op when the symlink doesn't exist (e.g. fresh install).
    systemctl disable "$mount_name" >/dev/null 2>&1 || true

    if systemctl daemon-reload 2>/dev/null \
       && systemctl enable "$automount_name" >/dev/null 2>&1; then
        log_info "systemd .mount + .automount installed: $mount_name (lazy)"
    else
        log_warn "systemd units written but automount enable failed: $automount_name"
    fi
}

setup_music_source() {
    case "${MUSIC_SOURCE:-}" in
        streaming)
            mkdir -p /media/music
            export MUSIC_PATH="/media/music"
            export MUSIC_SOURCE="streaming-only"
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
                    # Use UUID in fstab (stable across port/device changes)
                    local usb_uuid
                    usb_uuid=$(blkid -s UUID -o value "$usb_dev" 2>/dev/null) || true
                    local fstab_entry
                    if [[ -n "$usb_uuid" ]]; then
                        fstab_entry="UUID=$usb_uuid"
                    else
                        fstab_entry="$usb_dev"  # fallback if no UUID
                    fi
                    if ! grep -qF "$fstab_entry" /etc/fstab; then
                        echo "$fstab_entry $usb_mount auto ro,nofail 0 0" >> /etc/fstab
                    fi
                    export MUSIC_PATH="$usb_mount"
                    export MUSIC_SOURCE="usb"
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
            # Generate a hand-crafted systemd .mount unit instead of
            # writing /etc/fstab. The overlayroot initramfs hook
            # rewrites fstab during the first post-overlayroot boot,
            # mapping `/media/nfs-music` to `/media/root-ro/media/
            # nfs-music` AND stripping `nofail` in the process. The
            # rewritten line then triggers a hard `local-fs.target`
            # failure when the NAS is slow to answer the very first
            # mount attempt — systemd lands in emergency.target with
            # "Cannot open access to console, the root account is
            # locked. Press Enter to continue", forcing the user to
            # reboot manually for a second attempt where the DNS / ARP
            # caches are warm.
            #
            # Files in /etc/systemd/system/ are NOT rewritten by the
            # overlayroot hook, so a hand-crafted .mount unit keeps
            # the path stable AND honours the original options
            # including nofail (via Options= and the unit-level
            # `RequiredBy=` defaults that don't enrol the unit into
            # local-fs.target).
            _write_systemd_mount_unit nfs "${NFS_SERVER}:${NFS_EXPORT}" \
                "$mount_point" \
                "ro,soft,timeo=50,rsize=32768,_netdev,nofail" \
                45
            export MUSIC_PATH="$mount_point"
            export MUSIC_SOURCE="nfs"
            # Try mount immediately; failure is non-fatal because the
            # systemd unit retries every boot.
            if timeout 30 mount -t nfs "${NFS_SERVER}:${NFS_EXPORT}" "$mount_point" -o ro,soft,timeo=50,rsize=32768,_netdev; then
                log_info "NFS mounted: $mount_point"
            else
                log_warn "NFS mount timed out or failed — systemd unit will retry on next boot (MUSIC_PATH=$mount_point already exported)"
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

            # Same rationale as the NFS branch — overlayroot rewriter
            # would strip `nofail` from a fstab line and route systemd
            # into emergency mode on first-boot SMB hiccup.
            _write_systemd_mount_unit cifs "//${SMB_SERVER}/${SMB_SHARE}" \
                "$mount_point" \
                "${mount_opts},nofail" \
                60
            export MUSIC_PATH="$mount_point"
            export MUSIC_SOURCE="smb"
            if timeout 60 mount -t cifs "//${SMB_SERVER}/${SMB_SHARE}" "$mount_point" -o "$mount_opts"; then
                log_info "SMB mounted: $mount_point"
            else
                log_warn "SMB mount timed out or failed — systemd unit will retry on next boot (MUSIC_PATH=$mount_point already exported)"
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
