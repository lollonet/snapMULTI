#!/usr/bin/env bash
# Behavioural test for the MPD database round trip through the boot
# partition: backup-mpd.sh writes it, restore-snapmulti-state.sh puts it
# back before the containers start. Both scripts run end to end against a
# sandbox (mount / findmnt / flock / logger / docker are PATH stubs).
#
# Regressions covered:
#   - restore never copied mpd.db back, so under overlayroot every reboot
#     rolled the library back to install day and the next backup run
#     copied that stale DB over the good one
#   - a daily run with an unchanged DB still remounted and rewrote FAT32
#   - the backup was a plain cp over the published file (a power cut
#     mid-copy left a truncated mpd.db)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKUP_SH="$SCRIPT_DIR/../scripts/common/backup-mpd.sh"
RESTORE_SH="$SCRIPT_DIR/../scripts/common/restore-snapmulti-state.sh"

pass=0
fail=0

assert() {
    local cond="$1" desc="$2"
    if eval "$cond"; then
        echo "  PASS: $desc"
        pass=$((pass + 1))
    else
        echo "  FAIL: $desc"
        fail=$((fail + 1))
    fi
}

SBX="$(mktemp -d)"
trap 'rm -rf "$SBX"' EXIT
mkdir -p "$SBX/bin"

# mount with no args: report an overlay root when $STUB/overlay exists.
# mount -o remount,{rw,ro} <dir>: record the call, flip the findmnt state.
cat > "$SBX/bin/mount" <<'EOF'
#!/usr/bin/env bash
if [[ $# -eq 0 ]]; then
    [[ -e "$STUB/overlay" ]] && echo 'overlayroot on / type overlay (rw)'
    exit 0
fi
echo "mount $*" >> "$STUB/calls"
case "$*" in *remount,rw*) echo rw > "$STUB/mountstate" ;; *remount,ro*) echo ro > "$STUB/mountstate" ;; esac
EOF
cat > "$SBX/bin/findmnt" <<'EOF'
#!/usr/bin/env bash
echo "$(cat "$STUB/mountstate"),relatime"
EOF
cat > "$SBX/bin/logger" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$STUB/log"
EOF
# docker inspect -> $STUB/container_state; docker cp mpd:/data/mpd.db DEST.
cat > "$SBX/bin/docker" <<'EOF'
#!/usr/bin/env bash
case "$1" in
    inspect) cat "$STUB/container_state" ;;
    cp) cp "$STUB/container.db" "$3" ;;
    *) exit 1 ;;
esac
EOF
printf '#!/bin/sh\nexit 0\n' > "$SBX/bin/flock"
chmod +x "$SBX/bin/"*

INSTALL="$SBX/install"
BOOT_DIR="$SBX/boot"
LIVE_DB="$INSTALL/mpd/data/mpd.db"
BACKUP_DB="$BOOT_DIR/snapmulti-backup/mpd/data/mpd.db"

# A gzip mpd.db (mpd.conf sets compress "yes"), unique per label.
make_db() {
    mkdir -p "$(dirname "$1")"
    { echo "info_begin $2"; head -c 3000 /dev/urandom | base64; } | gzip > "$1"
}

reset_case() {
    rm -rf "${SBX:?}/install" "${SBX:?}/boot" "$SBX/run" "$SBX/tmp" "$SBX/overlay"
    mkdir -p "$INSTALL" "$BOOT_DIR" "$SBX/run" "$SBX/tmp"
    : > "$SBX/calls"
    : > "$SBX/log"
    echo ro > "$SBX/mountstate"
    echo running > "$SBX/container_state"
    touch "$SBX/overlay"
}

run_restore() {
    STUB="$SBX" PATH="$SBX/bin:$PATH" BOOT="$BOOT_DIR" INSTALL_DIR="$INSTALL" \
        RESTORE_GUARD="$SBX/run/restore.complete" bash "$RESTORE_SH" 2>>"$SBX/log"
}

run_backup() {
    : > "$SBX/calls"
    STUB="$SBX" PATH="$SBX/bin:$PATH" TMPDIR="$SBX/tmp" BOOT="$BOOT_DIR" \
        INSTALL_DIR="$INSTALL" SNAPMULTI_BOOT_LOCK="$SBX/lock" bash "$BACKUP_SH"
}

remounts() { local c; c=$(grep -c 'remount,rw' "$SBX/calls" 2>/dev/null) || true; echo "${c:-0}"; }

echo "## Restore at boot"
reset_case
make_db "$BACKUP_DB" newer
make_db "$LIVE_DB" install-day
run_restore
assert "cmp -s '$BACKUP_DB' '$LIVE_DB'" "backup replaces the install-day DB"
assert "[[ -f '$SBX/run/restore.complete' ]]" "restore guard written"
assert "! ls '$INSTALL/mpd/data/' | grep -q restore" "no staging file left in the live tree"

reset_case
make_db "$BACKUP_DB" newer
run_restore
assert "cmp -s '$BACKUP_DB' '$LIVE_DB'" "backup restored when no live DB exists"

reset_case
mkdir -p "$(dirname "$BACKUP_DB")"
head -c 4000 /dev/urandom | base64 > "$BACKUP_DB"
make_db "$LIVE_DB" install-day
cp "$LIVE_DB" "$SBX/live.orig"
assert "run_restore" "damaged backup does not fail the restore"
assert "cmp -s '$SBX/live.orig' '$LIVE_DB'" "damaged backup leaves the live DB alone"
assert "grep -q 'is damaged' '$SBX/log'" "damaged backup is logged"

reset_case
rm "$SBX/overlay"
make_db "$BACKUP_DB" older
make_db "$LIVE_DB" ext4-live
cp "$LIVE_DB" "$SBX/live.orig"
run_restore
assert "cmp -s '$SBX/live.orig' '$LIVE_DB'" "overlayroot off: persistent ext4 DB kept"

reset_case
mkdir -p "$BOOT_DIR/snapmulti-backup/data"
run_restore
assert "[[ ! -e '$LIVE_DB' ]]" "no DB backup: nothing created"

echo
echo "## Backup"
reset_case
make_db "$SBX/container.db" scanned
run_backup
assert "cmp -s '$SBX/container.db' '$BACKUP_DB'" "first run publishes the container DB"
assert "[[ \"\$(remounts)\" == 1 ]]" "boot partition remounted rw once"
assert "[[ \"\$(cat '$SBX/mountstate')\" == ro ]]" "boot partition back to ro afterwards"
assert "[[ -z \"\$(ls '$SBX/tmp')\" ]]" "temp copy removed"

touch -t 202001010000 "$BACKUP_DB"
# shellcheck disable=SC2034  # read inside assert's eval
before=$(ls -l "$BACKUP_DB")
run_backup
assert "[[ \"\$(remounts)\" == 0 ]]" "unchanged DB: no remount"
assert "[[ \"\$(ls -l '$BACKUP_DB')\" == \"\$before\" ]]" "unchanged DB: backup file not rewritten"
assert "[[ -z \"\$(ls '$SBX/tmp')\" ]]" "unchanged DB: temp copy removed"

make_db "$SBX/container.db" rescanned
touch "$BACKUP_DB.tmp.99999"
run_backup
assert "cmp -s '$SBX/container.db' '$BACKUP_DB'" "changed DB replaces the backup"
assert "[[ -z \"\$(ls '$BOOT_DIR/snapmulti-backup/mpd/data/' | grep tmp)\" ]]" "no staging file left on the boot partition"

cp "$BACKUP_DB" "$SBX/backup.orig"
echo 'not a database' > "$SBX/container.db"
run_backup
assert "cmp -s '$SBX/backup.orig' '$BACKUP_DB'" "damaged container DB keeps the good backup"
assert "[[ \"\$(remounts)\" == 0 ]]" "damaged container DB: no remount"

echo exited > "$SBX/container_state"
make_db "$LIVE_DB" host-copy
run_backup
assert "cmp -s '$LIVE_DB' '$BACKUP_DB'" "container down: host copy backed up"

echo
echo "## Round trip across a reboot"
reset_case
make_db "$LIVE_DB" install-day
make_db "$SBX/container.db" after-rescan
run_backup
make_db "$LIVE_DB" install-day    # overlayroot: the live tree is back to ext4
run_restore
assert "cmp -s '$SBX/container.db' '$LIVE_DB'" "rescanned DB survives the reboot"
cp "$LIVE_DB" "$SBX/container.db"   # MPD starts from the restored DB
run_backup
assert "[[ \"\$(remounts)\" == 0 ]]" "boot-time backup does not rewrite the restored DB"

echo
echo "Results: $pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
