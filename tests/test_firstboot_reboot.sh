#!/usr/bin/env bash
# shellcheck disable=SC2016
#
# Static check for the firstboot reboot pattern.
#
# Why: firstboot.sh runs from cloud-init's `runcmd`, i.e. inside the
# `cloud-final.service` unit. Calling bare `reboot` from that context
# can deadlock against systemd's own shutdown sequencing — the unit is
# still active when the synchronous reboot tries to stop it. Switching
# to `systemctl reboot --no-block` lets systemd schedule the reboot
# through the normal job manager, returning control to the script
# (which then exits 0) and letting cloud-final close cleanly.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FIRSTBOOT="$SCRIPT_DIR/../scripts/firstboot.sh"

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

echo "=== firstboot.sh — non-blocking reboot pattern ==="

# The new pattern is in place.
assert 'grep -qE "^systemctl reboot --no-block$" "$FIRSTBOOT"' \
       'firstboot uses systemctl reboot --no-block (non-blocking)'

# `sync` runs before reboot to flush write-back cache.
sync_line=$(grep -nE "^sync$" "$FIRSTBOOT" | tail -1 | cut -d: -f1)
reboot_line=$(grep -nE "^systemctl reboot --no-block$" "$FIRSTBOOT" | head -1 | cut -d: -f1)
if [[ -n "$sync_line" && -n "$reboot_line" && "$sync_line" -lt "$reboot_line" ]]; then
    echo "  PASS: sync runs before reboot (line $sync_line < $reboot_line)"
    pass=$((pass + 1))
else
    echo "  FAIL: sync/reboot ordering wrong (sync=$sync_line, reboot=$reboot_line)"
    fail=$((fail + 1))
fi

# Explicit `exit 0` so cloud-init records a successful runcmd. Without
# it, the script's exit status is whatever the last command returned —
# `systemctl reboot --no-block` exits 0 normally, but on a system where
# systemd is in a weird state it can return non-zero, and we want
# cloud-init to NOT retry runcmd.
exit_line=$(grep -nE "^exit 0$" "$FIRSTBOOT" | tail -1 | cut -d: -f1)
if [[ -n "$exit_line" && -n "$reboot_line" && "$exit_line" -gt "$reboot_line" ]]; then
    echo "  PASS: explicit exit 0 follows reboot (line $exit_line > $reboot_line)"
    pass=$((pass + 1))
else
    echo "  FAIL: missing or misordered exit 0 (exit=$exit_line, reboot=$reboot_line)"
    fail=$((fail + 1))
fi

# The bare `reboot` call must not reappear at the bottom of the file.
# Other occurrences of the word `reboot` are fine (in comments, log
# messages, etc.) — we anchor on a line that is exactly `reboot`.
assert '! grep -qE "^reboot$" "$FIRSTBOOT"' \
       'no bare `reboot` line remains (would deadlock under cloud-final.service)'

echo
echo "=== Bash syntax ==="
if bash -n "$FIRSTBOOT"; then
    echo "  PASS: bash -n firstboot.sh"
    pass=$((pass + 1))
else
    echo "  FAIL: bash -n firstboot.sh"
    fail=$((fail + 1))
fi

echo
echo "=== Summary ==="
echo "  Pass: $pass"
echo "  Fail: $fail"

[[ "$fail" -eq 0 ]]
