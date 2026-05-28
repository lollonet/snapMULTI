#!/usr/bin/env bash
# Backup snapserver group state and the WHOLE myMPD workdir to the
# boot partition. Independent from the MPD database backup: group +
# myMPD user config/playlists/scripts/theme must persist even when
# MPD is absent, restarting, or still scanning.
#
# Scope: whole /opt/snapmulti/mympd/workdir/ (state + config +
# smartpls + scripts + pics). Narrowing to state/ alone silently
# loses user-customised smart playlists, scripts, theme, and
# uploaded cover art on reboot.
set -euo pipefail

if [[ -d /opt/snapmulti ]]; then
    INSTALL_DIR="${INSTALL_DIR:-/opt/snapmulti}"
else
    exit 0
fi

if [[ -d /boot/firmware ]]; then
    BOOT=/boot/firmware
else
    BOOT=/boot
fi

BACKUP_DIR="$BOOT/snapmulti-backup"
backed_up=0

# Preserve the boot partition's prior mount state. During firstboot
# (both-mode) /boot/firmware is rw because raspi-config + cmdline
# patcher need to write to it; unconditionally remounting ro on exit
# there broke quiet-boot patching and raspi-config do_overlayfs in
# v0.7.9 (regression root cause — overlay never activated on snapvideo).
# Post-firstboot the partition is typically ro for SD wear protection;
# we restore THAT state on exit.
boot_was_ro=false
if findmnt -n -o OPTIONS "$BOOT" 2>/dev/null | tr ',' '\n' | grep -qx ro; then
    boot_was_ro=true
fi

mount -o remount,rw "$BOOT" 2>/dev/null || true
cleanup_boot_mount() {
    if [[ "$boot_was_ro" == "true" ]]; then
        mount -o remount,ro "$BOOT" 2>/dev/null || true
    fi
}
trap cleanup_boot_mount EXIT

backup_server_json() {
    local src="$INSTALL_DIR/data/server.json"
    local dst_dir="$BACKUP_DIR/data"
    local tmp="$dst_dir/server.json.tmp.$$"

    [[ -s "$src" ]] || return 0
    (( $(wc -c < "$src") >= 64 )) || return 0

    mkdir -p "$dst_dir"
    cp "$src" "$tmp"
    mv "$tmp" "$dst_dir/server.json"
    backed_up=1
}

backup_mympd_workdir() {
    local src="$INSTALL_DIR/mympd/workdir"
    local dst_parent="$BACKUP_DIR/mympd"
    local tmp="$dst_parent/workdir.tmp.$$"
    local old="$dst_parent/workdir.old.$$"

    [[ -d "$src" ]] || return 0

    mkdir -p "$dst_parent"
    rm -rf "$tmp" "$old"
    cp -R "$src" "$tmp"
    if [[ -d "$dst_parent/workdir" ]]; then
        mv "$dst_parent/workdir" "$old"
    fi
    mv "$tmp" "$dst_parent/workdir"
    rm -rf "$old"
    backed_up=1
}

backup_server_json
backup_mympd_workdir

if (( backed_up == 1 )); then
    logger -t backup-snapmulti-state "snapserver state + myMPD workdir backed up to $BACKUP_DIR"
else
    logger -t backup-snapmulti-state "skipped: no snapserver/myMPD state found"
fi
