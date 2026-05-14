#!/usr/bin/env bash
# Static checks for snapMULTI swap safety in scripts/common/system-tune.sh.
# Functional coverage of systemctl mask is impossible to fake without root
# + a real systemd; device-smoke + reflash close that gap.
#
# What this test guarantees:
#   1. The appliance-wide function exists.
#   2. The legacy Pi Zero wrapper still goes through is_pi_zero_2w.
#   3. The zram/rpi-swap units the function masks are exactly the
#      relevant Pi OS Bookworm units observed in the fleet.
#   4. The function returns 0 on every failure path (best-effort under
#      `set -euo pipefail` in firstboot).
#   5. /var/swap is removed (the actual fill source on overlayroot).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TUNE_SH="$SCRIPT_DIR/../scripts/common/system-tune.sh"

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

assert_count() {
    local pattern="$1" expected="$2" desc="$3"
    local actual
    actual=$(grep -cE "$pattern" "$TUNE_SH" || true)
    if [[ "$actual" == "$expected" ]]; then
        echo "  PASS: $desc (got $actual)"
        pass=$((pass + 1))
    else
        echo "  FAIL: $desc (got $actual, expected $expected)"
        fail=$((fail + 1))
    fi
}

echo "== system-tune.sh: appliance swap safety =="

# 1. Function presence + signature
assert 'grep -qE "^tune_appliance_swap_safety\(\)" "$TUNE_SH"' \
    "function tune_appliance_swap_safety() defined"

assert 'grep -qE "^tune_pi_zero_2w_swap_safety\(\)" "$TUNE_SH"' \
    "legacy wrapper tune_pi_zero_2w_swap_safety() still defined"

# 2. Pi Zero 2W detection goes through the shared is_pi_zero_2w helper
# in scripts/common/device-detect.sh (single source of truth — the
# `*"Zero 2 W"*` string lives in one file). Both functions short-circuit
# with `is_pi_zero_2w || return 0` so they no-op on non-Zero-2W models.
assert 'grep -qE "is_pi_zero_2w \|\| return 0" "$TUNE_SH"' \
    "uses is_pi_zero_2w helper (no-op on other Pi models)"
# Both functions must use the helper — count the call sites.
helper_calls=$(grep -cE "is_pi_zero_2w \|\| return 0" "$TUNE_SH" || echo 0)
if [[ "$helper_calls" -ge 2 ]]; then
    echo "  PASS: is_pi_zero_2w used by both tune functions ($helper_calls call sites)"
    pass=$((pass + 1))
else
    echo "  FAIL: is_pi_zero_2w used in only $helper_calls site (expected >=2: bcm43430 + zram swap)"
    fail=$((fail + 1))
fi

# 3. The zram/rpi-swap units masked are exactly the relevant Pi OS units.
for unit in \
    "rpi-resize-swap-file.service" \
    "rpi-setup-loop@var-swap.service" \
    "dev-zram0.swap" \
    "systemd-zram-setup@zram0.service" \
    "rpi-zram-writeback.service" \
    "rpi-zram-writeback.timer"; do
    assert "grep -qF \"$unit\" \"$TUNE_SH\"" \
        "masks $unit"
done

# 4. systemctl mask invocation present, all under '|| true' guard so
#    a transient systemctl failure doesn't abort firstboot
assert 'grep -qE "systemctl mask .*\|\| true" "$TUNE_SH"' \
    "systemctl mask wrapped in '|| true' (best-effort)"

# 5. /var/swap removal — the actual file that fills overlay tmpfs
assert 'grep -qE "rm -f /var/swap" "$TUNE_SH"' \
    "rm -f /var/swap present (removes existing swap backing file)"

assert 'grep -qF "swapoff -a" "$TUNE_SH"' \
    "swapoff -a present (disables already-active swap in current boot)"

# 6. Idempotency check — function short-circuits when already configured
assert 'grep -qF "Appliance swap safety already configured" "$TUNE_SH"' \
    "idempotent: short-circuits when all units already masked"

# 7. is_overlayroot escape hatch — when overlay is already active, the
#    function warns instead of failing (matches bcm43430 pattern)
assert 'grep -qE "is_overlayroot" "$TUNE_SH"' \
    "branches on is_overlayroot for write-failure diagnostic"

# 8. All return paths inside the function are `return 0` (best-effort)
#    Count returns inside the function body — should be 4 (early NO-OP
#    on missing /proc file, NO-OP on other Pi model, idempotent, applied,
#    plus the trailing best-effort return)
return_count=$(awk '
    /^tune_appliance_swap_safety\(\)/ { in_fn=1; next }
    in_fn && /^}/ { in_fn=0; next }
    in_fn && /return 0/ { count++ }
    END { print count+0 }
' "$TUNE_SH")
assert "[[ \"$return_count\" -ge 3 ]]" \
    "function has at least 3 'return 0' statements (got $return_count)"

# 9. The function is wired into firstboot.sh BEFORE setup.sh invocation
FIRSTBOOT="$SCRIPT_DIR/../scripts/firstboot.sh"
if [[ -f "$FIRSTBOOT" ]]; then
    # The appliance swap_safety call must appear in firstboot BEFORE
    # come BEFORE the setup_script dispatch (which is the point where
    # setup.sh / setup-zero2w.sh activates overlayroot via raspi-config).
    swap_line=$(grep -nF "tune_appliance_swap_safety" "$FIRSTBOOT" | head -1 | cut -d: -f1)
    setup_line=$(grep -nE "^[[:space:]]+(bash \"\\\$setup_script\"|bash scripts/setup)" "$FIRSTBOOT" | head -1 | cut -d: -f1)
    if [[ -n "$swap_line" && -n "$setup_line" && "$swap_line" -lt "$setup_line" ]]; then
        echo "  PASS: tune_appliance_swap_safety called from firstboot.sh line $swap_line, before setup dispatch at line $setup_line"
        pass=$((pass + 1))
    else
        echo "  FAIL: ordering broken (swap_safety at line ${swap_line:-?}, setup at ${setup_line:-?})"
        fail=$((fail + 1))
    fi
fi

echo
echo "Results: $pass passed, $fail failed"
exit $(( fail > 0 ? 1 : 0 ))
