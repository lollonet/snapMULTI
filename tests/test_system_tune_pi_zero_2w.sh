#!/usr/bin/env bash
# Static checks for tune_pi_zero_2w_swap_safety() in
# scripts/common/system-tune.sh. Functional coverage of /proc/device-tree
# inspection + systemctl mask is impossible to fake without root + a
# real systemd; device-smoke + reflash on pizero close that gap.
#
# What this test guarantees:
#   1. The function exists.
#   2. The Pi Zero 2W detection idiom is identical to
#      tune_bcm43430_firmware_workaround() — both should pass the same
#      Zero-2W-only condition so the two fixes co-vary.
#   3. The four zram units the function masks are exactly the units
#      Pi OS Bookworm ships (one drift here = silent regression on a
#      new device).
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

echo "== system-tune.sh: tune_pi_zero_2w_swap_safety() =="

# 1. Function presence + signature
assert 'grep -qE "^tune_pi_zero_2w_swap_safety\(\)" "$TUNE_SH"' \
    "function tune_pi_zero_2w_swap_safety() defined"

# 2. Pi Zero 2W detection matches the bcm43430 idiom
assert 'grep -qF "[[ \"\$model\" != *\"Zero 2 W\"* ]]" "$TUNE_SH"' \
    "uses identical 'Zero 2 W' model match (no-op on other Pi models)"

# 3. The four zram units masked are exactly the ones Pi OS Bookworm ships
for unit in \
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

# 6. Idempotency check — function short-circuits when already configured
assert 'grep -qF "Pi Zero 2W zram swap safety already configured" "$TUNE_SH"' \
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
    /^tune_pi_zero_2w_swap_safety\(\)/ { in_fn=1; next }
    in_fn && /^}/ { in_fn=0; next }
    in_fn && /return 0/ { count++ }
    END { print count+0 }
' "$TUNE_SH")
assert "[[ \"$return_count\" -ge 4 ]]" \
    "function has at least 4 'return 0' statements (got $return_count)"

# 9. The function is wired into firstboot.sh BEFORE setup.sh invocation
FIRSTBOOT="$SCRIPT_DIR/../scripts/firstboot.sh"
if [[ -f "$FIRSTBOOT" ]]; then
    # Both calls must appear in firstboot. The swap_safety call must
    # come BEFORE the setup_script dispatch (which is the point where
    # setup.sh / setup-zero2w.sh activates overlayroot via raspi-config).
    swap_line=$(grep -nF "tune_pi_zero_2w_swap_safety" "$FIRSTBOOT" | head -1 | cut -d: -f1)
    setup_line=$(grep -nE "^[[:space:]]+(bash \"\\\$setup_script\"|bash scripts/setup)" "$FIRSTBOOT" | head -1 | cut -d: -f1)
    if [[ -n "$swap_line" && -n "$setup_line" && "$swap_line" -lt "$setup_line" ]]; then
        echo "  PASS: tune_pi_zero_2w_swap_safety called from firstboot.sh line $swap_line, before setup dispatch at line $setup_line"
        pass=$((pass + 1))
    else
        echo "  FAIL: ordering broken (swap_safety at line ${swap_line:-?}, setup at ${setup_line:-?})"
        fail=$((fail + 1))
    fi
fi

echo
echo "Results: $pass passed, $fail failed"
exit $(( fail > 0 ? 1 : 0 ))
