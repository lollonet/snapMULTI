#!/usr/bin/env bash
# Tests for scripts/smoke/check_thermal.sh.
#
# WHY THIS EXISTS — Pi 4 / 3B+ / Zero 2W all throttle the ARM clock at
# 80 °C and emergency-shutdown at 85 °C. The existing
# check_system.sh:220-250 reads `vcgencmd get_throttled` but that bitmask
# only flips AFTER the throttle event — by which point audio is already
# glitching. The instantaneous temperature catches "hot but no throttle
# yet" cases (bad enclosure / airflow / ambient) BEFORE the operator
# notices skipping playback.
#
# Test surface:
#   1. vcgencmd present + cold reading → pass
#   2. vcgencmd present + warm (75 °C) → warn
#   3. vcgencmd present + hot (82 °C)  → fail
#   4. vcgencmd absent + sysfs cold    → pass via sysfs fallback
#   5. neither sensor available        → info, no fail
#   6. sysfs malformed value           → info, no fail
#   7. function is sourced and exported by name (device-smoke wiring)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECK_THERMAL="$SCRIPT_DIR/../scripts/smoke/check_thermal.sh"

pass=0
fail=0

assert_contains() {
    local haystack="$1" needle="$2" desc="$3"
    if grep -qF -- "$needle" <<<"$haystack"; then
        echo "  PASS: $desc"
        pass=$((pass + 1))
    else
        echo "  FAIL: $desc (missing '$needle')"
        fail=$((fail + 1))
    fi
}

assert_not_contains() {
    local haystack="$1" needle="$2" desc="$3"
    if grep -qF -- "$needle" <<<"$haystack"; then
        echo "  FAIL: $desc (found '$needle')"
        fail=$((fail + 1))
    else
        echo "  PASS: $desc"
        pass=$((pass + 1))
    fi
}

MOCK_BIN="$(mktemp -d)"
FAKE_SYS="$(mktemp -d)"
trap 'rm -rf "$MOCK_BIN" "$FAKE_SYS"' EXIT

# Stub helpers so check_thermal can be sourced standalone.
section()   { printf 'SECTION %s\n' "$*"; }
pass_check(){ printf '[OK] %s\n' "$*"; }
fail_check(){ printf '[ERROR] %s\n' "$*"; }
warn()      { printf '[WARN] %s\n' "$*"; }
info()      { printf '[INFO] %s\n' "$*"; }

# Run check_thermal in a subshell with controlled PATH + sysfs path
# substitution. The function reads /sys/class/thermal/thermal_zone0/temp
# directly, so we LD_PRELOAD-equivalent it by overriding `cat` and
# `test -r` semantics via PATH redirection only when needed. We use a
# different strategy: redirect via a temporary copy of the function with
# the sysfs path swapped at source time.
run_check_thermal() {
    local vcgen_value="$1" sysfs_value="$2"

    # Build a per-invocation MOCK_BIN containing only vcgencmd (when
    # vcgen_value is given). PATH search picks our stub before the real
    # binary on the host (in particular: macOS dev machines never have
    # vcgencmd, so the absence-case naturally works there too).
    rm -f "$MOCK_BIN/vcgencmd"
    if [[ "$vcgen_value" != "ABSENT" ]]; then
        cat > "$MOCK_BIN/vcgencmd" <<EOF
#!/usr/bin/env bash
[[ "\${1:-}" == "measure_temp" ]] && { printf 'temp=%s\\n' "$vcgen_value"; exit 0; }
exit 1
EOF
        chmod +x "$MOCK_BIN/vcgencmd"
    fi

    # Sysfs stub: rewrite the path in a copy of check_thermal.sh so the
    # function reads from our temp file. Less brittle than shadowing
    # `cat` or trying to bind-mount.
    local temp_file=""
    if [[ "$sysfs_value" != "ABSENT" ]]; then
        temp_file="$FAKE_SYS/thermal_zone0_temp"
        printf '%s\n' "$sysfs_value" > "$temp_file"
    fi

    local rewritten="$FAKE_SYS/check_thermal_under_test.sh"
    if [[ -n "$temp_file" ]]; then
        sed "s#/sys/class/thermal/thermal_zone0/temp#${temp_file}#g" \
            "$CHECK_THERMAL" > "$rewritten"
    else
        # Point at a non-existent path so the `-r` test fails cleanly.
        sed "s#/sys/class/thermal/thermal_zone0/temp#${FAKE_SYS}/__missing__#g" \
            "$CHECK_THERMAL" > "$rewritten"
    fi

    PATH="$MOCK_BIN:/usr/bin:/bin" bash -c "
        section()   { printf 'SECTION %s\\n' \"\$*\"; }
        pass_check(){ printf '[OK] %s\\n' \"\$*\"; }
        fail_check(){ printf '[ERROR] %s\\n' \"\$*\"; }
        warn()      { printf '[WARN] %s\\n' \"\$*\"; }
        info()      { printf '[INFO] %s\\n' \"\$*\"; }
        source '$rewritten'
        check_thermal
    " 2>&1
}

echo "Testing check_thermal..."

# 1. Cold via vcgencmd
out=$(run_check_thermal "58.3'C" "ABSENT")
assert_contains "$out" "[OK] SoC 58.3°C via vcgencmd" "vcgencmd cold (58.3°C) → pass"
assert_not_contains "$out" "[WARN]" "vcgencmd cold → no warn"
assert_not_contains "$out" "[ERROR]" "vcgencmd cold → no fail"

# 2. Warm via vcgencmd
out=$(run_check_thermal "75.4'C" "ABSENT")
assert_contains "$out" "[WARN] SoC 75.4°C via vcgencmd" "vcgencmd warm (75.4°C) → warn"
assert_not_contains "$out" "[ERROR]" "vcgencmd warm → no fail"

# 3. Hot via vcgencmd
out=$(run_check_thermal "82.1'C" "ABSENT")
assert_contains "$out" "[ERROR] SoC 82.1°C via vcgencmd" "vcgencmd hot (82.1°C) → fail"
assert_contains "$out" "throttle threshold" "fail message mentions throttle threshold"

# 4. vcgencmd absent → sysfs fallback
out=$(run_check_thermal "ABSENT" "55300")
assert_contains "$out" "[OK] SoC 55.3°C via sysfs" "sysfs fallback (55.3°C) → pass"

# 5. Neither sensor → info, no fail
out=$(run_check_thermal "ABSENT" "ABSENT")
assert_contains "$out" "[INFO] No thermal sensor accessible" "no sensor → info"
assert_not_contains "$out" "[ERROR]" "no sensor → no fail"
assert_not_contains "$out" "[WARN]" "no sensor → no warn"

# 6. Sysfs malformed value → info, no fail
out=$(run_check_thermal "ABSENT" "not-a-number")
assert_contains "$out" "[INFO] No thermal sensor accessible" "malformed sysfs → info (rejected by sanity check)"

# 7. Function name + section header for the dispatcher.
src="$(cat "$CHECK_THERMAL")"
assert_contains "$src" "check_thermal()" "function check_thermal defined"
assert_contains "$src" 'section "Thermal"' "section header is Thermal"

# 8. device-smoke wiring — module sourced AND dispatched.
DS="$SCRIPT_DIR/../scripts/device-smoke.sh"
ds_src="$(cat "$DS")"
assert_contains "$ds_src" "check_thermal.sh \\" "check_thermal.sh listed in source loop"
assert_contains "$ds_src" "declare -F check_thermal" "check_thermal called from dispatcher"

echo ""
if [[ "$fail" -gt 0 ]]; then
    echo "FAILED: $fail tests failed, $pass passed"
    exit 1
fi
echo "All $pass tests passed!"
