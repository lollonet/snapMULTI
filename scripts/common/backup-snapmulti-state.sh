#!/usr/bin/env bash
# Backup snapserver group state and myMPD user state to the boot
# partition. This is intentionally independent from the MPD database
# backup: group/playlists/theme state must persist even when MPD is
# absent, restarting, or still scanning.
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

mount -o remount,rw "$BOOT" 2>/dev/null || true
trap 'mount -o remount,ro "$BOOT" 2>/dev/null || true' EXIT

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

backup_mympd_state() {
    local src="$INSTALL_DIR/mympd/workdir/state"
    local dst_parent="$BACKUP_DIR/mympd"
    local tmp="$dst_parent/state.tmp.$$"
    local old="$dst_parent/state.old.$$"

    [[ -d "$src" ]] || return 0

    mkdir -p "$dst_parent"
    rm -rf "$tmp" "$old"
    cp -R "$src" "$tmp"
    if [[ -d "$dst_parent/state" ]]; then
        mv "$dst_parent/state" "$old"
    fi
    mv "$tmp" "$dst_parent/state"
    rm -rf "$old"
    backed_up=1
}

backup_server_json
backup_mympd_state

if (( backed_up == 1 )); then
    logger -t backup-snapmulti-state "snapserver/myMPD state backed up to $BACKUP_DIR"
else
    logger -t backup-snapmulti-state "skipped: no snapserver/myMPD state found"
fi
