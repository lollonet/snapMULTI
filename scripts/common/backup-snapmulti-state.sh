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
#
# Runs on every .path event and every 5-min .timer tick, so a no-op run
# must not touch the FAT boot partition: both artefacts are compared
# with what was last published (server.json by canonical content,
# workdir by a content hash) and the partition is only remounted rw
# when at least one of them actually changed.
set -euo pipefail

INSTALL_DIR="${INSTALL_DIR:-/opt/snapmulti}"
[[ -d "$INSTALL_DIR" ]] || exit 0

if [[ -z "${BOOT:-}" ]]; then
    if [[ -d /boot/firmware ]]; then
        BOOT=/boot/firmware
    else
        BOOT=/boot
    fi
fi

BACKUP_DIR="$BOOT/snapmulti-backup"
backed_up=0

# Serialise /boot/firmware mount/write with sibling backup scripts (see
# backup-mpd.sh for the race scenario). Without this, our EXIT trap can
# remount ro while a sibling is still mid-write, or vice versa.
# (SNAPMULTI_BOOT_LOCK only relocates the lock for the test suite.)
if [[ -n "${SNAPMULTI_BOOT_LOCK:-}" ]]; then
    exec 9>"$SNAPMULTI_BOOT_LOCK"
else
    exec 9>/run/snapmulti-boot-write.lock
fi
if ! flock -w 60 9; then
    logger -t backup-snapmulti-state "skipped: could not acquire /run/snapmulti-boot-write.lock within 60s"
    exit 0
fi

# ---------- Change detection (read-only, before any remount) --------------

# sha256 of server.json with keys sorted and `lastSeen` stripped; empty
# when jq / sha256sum are missing or the file does not parse.
#
# Critical: under `set -euo pipefail`, a `jq` parse failure in the
# pipeline would abort the entire script before reaching the `.prev`
# rotation / preservation path — the exact moment we must NOT abort,
# because a corrupt backup is precisely the recovery case that rotation
# handles. The `|| _h=""` guard leaves the hash empty instead, which
# makes the canonical-equal check false so the publish path runs.
server_json_canonical_hash() {
    command -v jq >/dev/null 2>&1 && command -v sha256sum >/dev/null 2>&1 || return 0
    local _h=""
    _h=$(jq -S 'walk(if type == "object" then del(.lastSeen) else . end)' "$1" 2>/dev/null | sha256sum | cut -d' ' -f1) || _h=""
    printf '%s' "$_h"
}

# True when server.json must be (re)published.
#
# Canonical-equal short-circuit. snapserver rewrites server.json every
# ~3 s to refresh client `lastSeen` heartbeats. Those rewrites do not
# change any state worth persisting — comparing the canonicalized
# (sorted keys, lastSeen stripped) source against the same projection
# of the existing backup lets us skip the publish entirely on
# heartbeat-only churn, preventing a backup loop on FAT32. Without jq
# we fall through to the unconditional publish path (early in
# firstboot, before install_dependencies).
server_json_changed() {
    local src="$INSTALL_DIR/data/server.json"
    local dst="$BACKUP_DIR/data/server.json"
    [[ -s "$src" ]] || return 1
    (( $(wc -c < "$src") >= 64 )) || return 1
    [[ -s "$dst" ]] || return 0
    local _canon_src _canon_dst
    _canon_src=$(server_json_canonical_hash "$src")
    _canon_dst=$(server_json_canonical_hash "$dst")
    [[ -n "$_canon_src" && -n "$_canon_dst" && "$_canon_src" == "$_canon_dst" ]] && return 1
    return 0
}

# Content hash of the live myMPD workdir: file names, contents, modes and
# symlink targets. Owner and mtime are normalised away so a no-op rewrite
# by myMPD does not count as a change. Empty when tar fails (e.g. a file
# changed while being read) — the caller then publishes, as before.
workdir_hash() {
    local _h=""
    _h=$(tar --sort=name --mtime=@0 --owner=0 --group=0 --numeric-owner \
            -C "$1" -cf - . 2>/dev/null | sha256sum | cut -d' ' -f1) || _h=""
    printf '%s' "$_h"
}

MYMPD_SRC="$INSTALL_DIR/mympd/workdir"
MYMPD_DST_PARENT="$BACKUP_DIR/mympd"
MYMPD_HASH_FILE="$MYMPD_DST_PARENT/workdir.sha256"

do_server_json=false
server_json_changed && do_server_json=true

do_mympd=false
mympd_hash=""
if [[ -d "$MYMPD_SRC" ]]; then
    mympd_hash=$(workdir_hash "$MYMPD_SRC")
    if [[ -z "$mympd_hash" || ! -d "$MYMPD_DST_PARENT/workdir" ]] \
        || [[ "$(cat "$MYMPD_HASH_FILE" 2>/dev/null || true)" != "$mympd_hash" ]]; then
        do_mympd=true
    fi
fi

if [[ "$do_server_json" == "false" && "$do_mympd" == "false" ]]; then
    # Nothing changed since the last publish: no remount, no FAT write.
    exit 0
fi

# ---------- Publish -------------------------------------------------------

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

    mkdir -p "$dst_dir"
    # Leftovers of runs killed mid-copy (other PIDs) would otherwise
    # accumulate on the boot partition.
    rm -f "$dst_dir"/server.json.tmp.*

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
    local dst_parent="$MYMPD_DST_PARENT"
    local tmp="$dst_parent/workdir.tmp.$$"
    local old="$dst_parent/workdir.old.$$"

    mkdir -p "$dst_parent"
    # Remove staging leftovers of earlier runs (any PID): a failed or
    # killed cp used to leave workdir.tmp.<pid> behind on every attempt
    # until the boot partition filled up.
    rm -rf "$dst_parent"/workdir.tmp.* "$dst_parent"/workdir.old.*

    if ! cp -R "$MYMPD_SRC" "$tmp"; then
        rm -rf "$tmp"
        logger -t backup-snapmulti-state "myMPD workdir: cp to temp failed, preserving prior backup"
        return 0
    fi
    # Invalidate the stored hash before swapping, so an interruption
    # between the swap and the hash write forces a re-publish next run.
    rm -f "$MYMPD_HASH_FILE"
    if [[ -d "$dst_parent/workdir" ]]; then
        mv "$dst_parent/workdir" "$old"
    fi
    mv "$tmp" "$dst_parent/workdir"
    rm -rf "$old"
    if [[ -n "$mympd_hash" ]]; then
        printf '%s\n' "$mympd_hash" > "$MYMPD_HASH_FILE"
    fi
    backed_up=1
}

if [[ "$do_server_json" == "true" ]]; then
    backup_server_json
fi
if [[ "$do_mympd" == "true" ]]; then
    backup_mympd_workdir
fi

if (( backed_up == 1 )); then
    logger -t backup-snapmulti-state "snapserver state / myMPD workdir changes backed up to $BACKUP_DIR"
else
    logger -t backup-snapmulti-state "skipped: changed state could not be copied (see previous messages)"
fi
