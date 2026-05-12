#!/usr/bin/env bash
# Static checks on client/common/scripts/setup.sh — audio HAT config.txt block.
#
# These mirror the assertions test_setup_zero2w.sh makes for the parallel
# block in setup-zero2w.sh, ensuring both code paths stay in sync.
#
# What this test guards:
#   1. The factory `dtparam=audio=on` is commented out when a HAT is
#      confirmed (eeprom / alsa source), preventing the firmware from
#      emitting duplicate `snd_bcm2835.enable_*` to /proc/cmdline.
#   2. The comment-out is guarded by both the HAT_DETECTION_SOURCE gate
#      AND a grep so re-runs are idempotent.
#   3. The marker-delimited audio block still removes the prior block
#      before re-emitting (existing invariant — kept as a regression guard).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SETUP="$SCRIPT_DIR/../client/common/scripts/setup.sh"

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

echo "Static checks on $SETUP"

assert '[[ -f "$SETUP" ]]'   "setup.sh exists"
assert '[[ -r "$SETUP" ]]'   "setup.sh is readable"

# 1. shellcheck + bash syntax (warning level — info-level findings are
#    pre-existing baseline, not our concern here).
assert 'shellcheck -S warning "$SETUP" >/dev/null 2>&1' \
    "setup.sh shellcheck clean at warning severity"
assert 'bash -n "$SETUP" 2>/dev/null' \
    "setup.sh bash syntax valid"

# 2. The factory dtparam=audio=on comment-out is gated on HAT confirmation.
#    Without this gate, USB / internal-audio paths would silently disable
#    on-board audio they actually need.
assert 'grep -qE "HAT_DETECTION_SOURCE.*==.*eeprom.*\\|\\|.*HAT_DETECTION_SOURCE.*==.*alsa" "$SETUP"' \
    "comment-out is gated on HAT_DETECTION_SOURCE == eeprom or alsa"

# 3. The sed pattern replaces the factory line with a commented-out
#    version. Pattern must match the exact line `^dtparam=audio=on` so we
#    don't accidentally rewrite other audio= lines.
assert 'grep -qE "sed -i .s/\\^dtparam=audio=on/" "$SETUP"' \
    "factory dtparam=audio=on is commented out via sed -i (anchored ^)"

# 4. The sed run is idempotent — guarded by grep so the second invocation
#    short-circuits when the line is already commented.
assert 'grep -qE "grep -qE .\\^dtparam=audio=on. \"\\\$BOOT_CONFIG\"" "$SETUP"' \
    "comment-out is guarded by grep for idempotency on re-run"

# 5. The dtparam=audio=off line emitted into the new marker block is also
#    gated on the same condition (existing invariant — regression guard).
assert 'awk "/dtparam=audio=off/{found=1} END{exit !found}" "$SETUP"' \
    "marker block still emits dtparam=audio=off"

# 6. The audio block is wrapped in a CONFIG_MARKER_START/END pair, removed
#    before re-emission (idempotency baseline).
assert 'grep -qE "CONFIG_MARKER_START" "$SETUP"' \
    "audio block uses CONFIG_MARKER_START sentinel"
assert 'grep -qE "sed -i .*CONFIG_MARKER_START.*CONFIG_MARKER_END.*d. \"\\\$BOOT_CONFIG\"" "$SETUP"' \
    "prior audio block is removed before re-emission (idempotent)"

echo
echo "Results: $pass passed, $fail failed"
exit $(( fail > 0 ? 1 : 0 ))
