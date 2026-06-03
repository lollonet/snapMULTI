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

# Spacing in the banner is cosmetic and changes when new lines are added
# (PR #488 added a "Start here" landing-page line that shifted the column).
# Assert URLs are present, not exact whitespace.
assert 'grep -qE "Snapweb:[[:space:]]+http://\\\$\\{LOCAL_HOSTNAME\\}\\.local:1780" "$FIRSTBOOT"' \
       'completion banner names Snapweb URL explicitly'

assert '! grep -qE "Speakers:[[:space:]]+http://" "$FIRSTBOOT"' \
       'completion banner no longer labels Snapweb as Speakers'

# Every user-facing URL the project publishes must appear in the banner.
# Snapweb 1780, myMPD 8180, Status 8083, and the TCP audio input 4953
# (documented in config/snapserver.conf:69 and docs/USAGE.md) are all
# end-user endpoints. The Snapcast streaming/RPC ports (1704/1705) and
# the metadata WS (8082) are intentionally omitted — internal protocol.
assert 'grep -qE "Library:[[:space:]]+http://\\\$\\{LOCAL_HOSTNAME\\}\\.local:8180" "$FIRSTBOOT"' \
       'completion banner names myMPD library URL'

assert 'grep -qE "Status:[[:space:]]+http://\\\$\\{LOCAL_HOSTNAME\\}\\.local:8083" "$FIRSTBOOT"' \
       'completion banner names Status page URL'

assert 'grep -qE "Stream in:[[:space:]]+tcp://\\\$\\{LOCAL_HOSTNAME\\}\\.local:4953" "$FIRSTBOOT"' \
       'completion banner names TCP audio input URL (Android/Termux/ffmpeg)'

echo
echo "=== firstboot.sh — installed systemd unit permissions ==="

assert '! grep -qE "cp .*\\.service.* /etc/systemd/system/" "$FIRSTBOOT"' \
       'firstboot does not cp .service files into /etc/systemd/system'

assert '! grep -qE "cp .*\\.timer.* /etc/systemd/system/" "$FIRSTBOOT"' \
       'firstboot does not cp .timer files into /etc/systemd/system'

# v0.8 PR8 — inline `install -m 0644 ... .service|.timer ... /etc/systemd/system/`
# was migrated to the install_systemd_unit_files BASE SRC_DIR helper
# defined in scripts/common/systemd-units.sh. The contract that
# firstboot ships static units to /etc/systemd/system/ at mode 0644 is
# now enforced by:
#   (a) firstboot.sh calling install_systemd_unit_files (asserted here)
#   (b) tests/test_systemd_units.sh verifying the helper covers every
#       base in SYSTEMD_UNITS_SERVER
#   (c) the helper itself using `install -m 0644 ... /etc/systemd/system/`
#       (verified in test_systemd_units.sh via helper inspection)
assert 'grep -qE "install_systemd_unit_files\\b" "$FIRSTBOOT"' \
       'firstboot installs systemd units via the manifest helper (PR8)'

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
