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

# Serialise /boot/firmware mount/write with sibling backup scripts (see
# backup-mpd.sh for the race scenario). Without this, our EXIT trap can
# remount ro while a sibling is still mid-write, or vice versa.
exec 9>/run/snapmulti-boot-write.lock
if ! flock -w 60 9; then
    logger -t backup-snapmulti-state "skipped: could not acquire /run/snapmulti-boot-write.lock within 60s"
    exit 0
fi

# Preserve the boot partition's prior mount state. During firstboot
# /boot/firmware is rw because raspi-config + cmdline patcher need to
# write to it; unconditionally remounting ro on exit there can break
# quiet-boot patching and raspi-config do_overlayfs. Post-firstboot
# the partition is typically ro for SD wear protection; we restore
# THAT state on exit.
boot_was_ro=false
if findmnt -n -o OPTIONS "$BOOT" 2>/dev/null | tr ',' '\n' | grep -qx ro; then
    boot_was_ro=true
fi

mount_err=$(mount -o remount,rw "$BOOT" 2>&1 || true)
cleanup_boot_mount() {
    if [[ "$boot_was_ro" == "true" ]]; then
        mount -o remount,ro "$BOOT" 2>/dev/null || true
    fi
}
trap cleanup_boot_mount EXIT

# See backup-mpd.sh — mount(8) can return 0 while fs stays ro; exit 0 so .path re-fires on next change.
if findmnt -n -o OPTIONS "$BOOT" 2>/dev/null | tr ',' '\n' | grep -qx ro; then
    logger -t backup-snapmulti-state \
        "skipped: $BOOT failed to remount rw (mount err: ${mount_err:-none})"
    exit 0
fi

backup_server_json() {
    local src="$INSTALL_DIR/data/server.json"
    local dst_dir="$BACKUP_DIR/data"
    local tmp="$dst_dir/server.json.tmp.$$"
    local dst="$dst_dir/server.json"
    local prev="$dst_dir/server.json.prev"

    [[ -s "$src" ]] || return 0
    (( $(wc -c < "$src") >= 64 )) || return 0

    mkdir -p "$dst_dir"

    # Canonical-equal short-circuit. snapserver rewrites server.json every
    # ~3 s to refresh client `lastSeen` heartbeats. Those rewrites do not
    # change any state worth persisting — comparing the canonicalized
    # (sorted keys, lastSeen stripped) source against the same projection
    # of the existing backup lets us skip the publish entirely on
    # heartbeat-only churn, preventing a backup loop on FAT32. Requires
    # jq; without jq we fall through to the unconditional publish path
    # (early in firstboot, before install_dependencies).
    #
    # Critical: under `set -euo pipefail`, a `jq` parse failure in the
    # pipeline below would abort the entire script before reaching the
    # `.prev` rotation / preservation path — the exact moment we must
    # NOT abort, because a corrupt $dst is precisely the recovery case
    # that rotation handles. Guard each $() with `|| _var=""` so a parse
    # error leaves the hash empty (forcing the canonical-equal check to
    # be false) and execution continues into the rotation path.
    if [[ -s "$dst" ]] && command -v jq >/dev/null 2>&1 && command -v sha256sum >/dev/null 2>&1; then
        local _canon_src="" _canon_dst=""
        _canon_src=$(jq -S 'walk(if type == "object" then del(.lastSeen) else . end)' "$src" 2>/dev/null | sha256sum | cut -d' ' -f1) || _canon_src=""
        _canon_dst=$(jq -S 'walk(if type == "object" then del(.lastSeen) else . end)' "$dst" 2>/dev/null | sha256sum | cut -d' ' -f1) || _canon_dst=""
        if [[ -n "$_canon_src" && -n "$_canon_dst" && "$_canon_src" == "$_canon_dst" ]]; then
            return 0
        fi
    fi

    # Stage to temp first. cp can fail mid-write on disk-full or FAT32
    # fragmentation; checking exit code lets us preserve any prior good
    # backup instead of publishing a partial file.
    if ! cp "$src" "$tmp"; then
        rm -f "$tmp"
        logger -t backup-snapmulti-state "server.json: cp to temp failed, preserving prior backup"
        return 0
    fi

    # Size sanity — published file must be at least as big as the
    # minimum we would have accepted from source.
    if (( $(wc -c < "$tmp") < 64 )); then
        rm -f "$tmp"
        logger -t backup-snapmulti-state "server.json: temp is smaller than minimum threshold, preserving prior backup"
        return 0
    fi

    # JSON validity (jq is in our install-deps.sh). If jq is missing
    # (e.g. early in firstboot before install_dependencies completes),
    # skip the validation rather than blocking the backup.
    if command -v jq >/dev/null 2>&1; then
        if ! jq -e . "$tmp" >/dev/null 2>&1; then
            rm -f "$tmp"
            logger -t backup-snapmulti-state "server.json: temp is not valid JSON, preserving prior backup"
            return 0
        fi
    fi

    # Rotate: current → .prev, then publish temp. Validate the
    # existing current before promoting it: after a restore-from-
    # .prev cycle, the current file on the boot partition is still
    # the corrupt copy that triggered the fallback. Blindly rotating
    # it to .prev would clobber the known-good fallback. Discard the
    # invalid current instead, keeping the existing .prev as our
    # grace generation. Same gates as the source validation above.
    if [[ -s "$dst" ]]; then
        local _dst_valid=true
        (( $(wc -c < "$dst") >= 64 )) || _dst_valid=false
        if [[ "$_dst_valid" == "true" ]] && command -v jq >/dev/null 2>&1; then
            jq -e . "$dst" >/dev/null 2>&1 || _dst_valid=false
        fi
        if [[ "$_dst_valid" == "true" ]]; then
            mv "$dst" "$prev"
        else
            rm -f "$dst"
            logger -t backup-snapmulti-state "server.json: existing current is corrupt; discarded without rotation to preserve .prev"
        fi
    fi
    mv "$tmp" "$dst"
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
