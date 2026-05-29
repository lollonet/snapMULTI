#!/usr/bin/env bash
# Static check: all three /boot/firmware writer scripts acquire a shared
# flock before remount/write, so a concurrent script's EXIT remount,ro
# cannot race against another's mid-write.
#
# Background: snapvideo 2026-05-29 17:16:44 — snapmulti-state-backup.service
# and snapmulti-backup.service both fired in the same second.
# state-backup's trap remounted /boot/firmware ro mid-write, mpd-backup hit
# 'mkdir: cannot create directory: Read-only file system' even though its
# own findmnt-validate check had passed moments earlier.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS=(
    "$SCRIPT_DIR/../scripts/common/backup-mpd.sh"
    "$SCRIPT_DIR/../scripts/common/backup-snapmulti-state.sh"
    "$SCRIPT_DIR/../scripts/common/save-diagnostics.sh"
)

pass=0
fail=0

assert_script() {
    local f="$1"
    local name
    name="$(basename "$f")"

    if [[ ! -f "$f" ]]; then
        echo "  FAIL: $name not found"
        fail=$((fail + 1))
        return
    fi

    # Must open FD 9 on the shared lock file.
    if grep -qE 'exec 9>/run/snapmulti-boot-write\.lock' "$f"; then
        echo "  PASS: $name opens FD 9 on /run/snapmulti-boot-write.lock"
        pass=$((pass + 1))
    else
        echo "  FAIL: $name missing 'exec 9>/run/snapmulti-boot-write.lock'"
        fail=$((fail + 1))
    fi

    # Must flock that FD with a timeout, and exit 0 on contention.
    if grep -qE 'flock -w [0-9]+ 9' "$f"; then
        echo "  PASS: $name uses 'flock -w <timeout> 9' (non-blocking-bounded)"
        pass=$((pass + 1))
    else
        echo "  FAIL: $name missing 'flock -w <timeout> 9'"
        fail=$((fail + 1))
    fi

    # The flock acquisition must precede the first mount call so a sibling
    # cannot run its EXIT trap on /boot/firmware while we are inside.
    flock_line=$(grep -nE '^if ! flock' "$f" | head -1 | cut -d: -f1)
    mount_line=$(grep -nE 'mount -o remount,rw' "$f" | head -1 | cut -d: -f1)
    if [[ -n "$flock_line" && -n "$mount_line" && "$flock_line" -lt "$mount_line" ]]; then
        echo "  PASS: $name flock (line $flock_line) precedes first mount (line $mount_line)"
        pass=$((pass + 1))
    else
        echo "  FAIL: $name flock NOT before mount (flock=$flock_line, mount=$mount_line)"
        fail=$((fail + 1))
    fi
}

for s in "${SCRIPTS[@]}"; do
    echo "=== $(basename "$s") ==="
    assert_script "$s"
    echo
done

echo "=== Summary ==="
echo "  Pass: $pass"
echo "  Fail: $fail"

if (( fail > 0 )); then
    exit 1
fi
