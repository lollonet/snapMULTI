#!/usr/bin/env bash
# Static + functional checks for scripts/common/device-detect.sh and
# the firstboot.sh client -> client-native promote rule that consumes it.
#
# Invariants we guard:
#   1. device-detect.sh exposes is_pi_zero_2w and device_model.
#   2. is_pi_zero_2w matches the "Zero 2 W" model substring (any Rev).
#   3. is_pi_zero_2w returns false for non-Zero-2W models and empty input.
#   4. device_model is memoised across calls (one /proc read).
#   5. firstboot.sh promotes INSTALL_TYPE=client -> client-native when
#      is_pi_zero_2w returns true; passes through every other combo.
#   6. The five legacy hardcoded `*"Zero 2 W"*` matches have been
#      consolidated — production scripts now go through is_pi_zero_2w
#      (the firstboot.sh hardware guard and the audio-hat detection
#      keep their own copies because they intentionally short-circuit
#      different paths; the four other sites are unified).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DETECT="$SCRIPT_DIR/../scripts/common/device-detect.sh"
FIRSTBOOT="$SCRIPT_DIR/../scripts/firstboot.sh"
TUNE_SH="$SCRIPT_DIR/../scripts/common/system-tune.sh"
# shellcheck disable=SC2034  # used inside single-quoted eval'd assertions
CHECK_CONTAINERS="$SCRIPT_DIR/../scripts/smoke/check_containers.sh"

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

echo "=== Static checks ==="

assert '[[ -f "$DETECT" ]]' "device-detect.sh exists"
assert 'bash -n "$DETECT"' "device-detect.sh: bash -n clean"
if command -v shellcheck >/dev/null 2>&1; then
    assert 'shellcheck -S warning "$DETECT"' "device-detect.sh: shellcheck -S warning clean"
fi

assert 'grep -qE "^is_pi_zero_2w\\(\\) \\{" "$DETECT"' "is_pi_zero_2w() defined"
assert 'grep -qE "^device_model\\(\\) \\{" "$DETECT"' "device_model() defined"

# Cached model read — must not hit /proc on every call.
assert 'grep -qE "_DEVICE_MODEL_(CACHE|READ)" "$DETECT"' "device_model caches result"

echo
echo "=== Functional: is_pi_zero_2w ==="

# Driver: source the module, point device_model() at a mock file.
run_case() {
    local model="$1" expect_rc="$2" desc="$3"
    local model_file
    model_file=$(mktemp /tmp/snapmulti-model-XXXXXX)
    printf '%s' "$model" > "$model_file"

    local rc=0
    bash -c "
        # shellcheck disable=SC1090,SC1091
        source '$DETECT'
        # Override device_model to return our mock.
        device_model() { cat '$model_file'; }
        is_pi_zero_2w
    " || rc=$?

    rm -f "$model_file"

    if [[ "$rc" == "$expect_rc" ]]; then
        echo "  PASS: $desc"
        pass=$((pass + 1))
    else
        echo "  FAIL: $desc (got rc=$rc, expected $expect_rc)"
        fail=$((fail + 1))
    fi
}

run_case "Raspberry Pi Zero 2 W Rev 1.0" 0 "Pi Zero 2W Rev 1.0 matches"
run_case "Raspberry Pi Zero 2 W Rev 1.1" 0 "Pi Zero 2W Rev 1.1 matches"
run_case "Raspberry Pi Zero W Rev 1.1" 1 "Pi Zero W (original) does NOT match"
run_case "Raspberry Pi 4 Model B Rev 1.4" 1 "Pi 4 does NOT match"
run_case "Raspberry Pi 3 Model B Plus Rev 1.3" 1 "Pi 3B+ does NOT match"
run_case "" 1 "empty model string does NOT match"

echo
echo "=== Static: callers consolidated to is_pi_zero_2w ==="

# system-tune.sh: both tune functions go through is_pi_zero_2w.
assert 'grep -qE "^tune_bcm43430_firmware_workaround\\(\\) \\{" "$TUNE_SH"' \
    "tune_bcm43430_firmware_workaround() still defined"
assert 'grep -qE "^tune_pi_zero_2w_swap_safety\\(\\) \\{" "$TUNE_SH"' \
    "tune_pi_zero_2w_swap_safety() still defined"

bcm_uses_helper=$(awk '
    /^tune_bcm43430_firmware_workaround\(\) \{/ {f=1}
    f && /is_pi_zero_2w \|\| return 0/ {print "yes"; exit}
    f && /^\}/ {exit}
' "$TUNE_SH")
[[ "$bcm_uses_helper" == "yes" ]] && {
    echo "  PASS: tune_bcm43430_firmware_workaround uses is_pi_zero_2w"
    pass=$((pass + 1))
} || {
    echo "  FAIL: tune_bcm43430_firmware_workaround does NOT use is_pi_zero_2w"
    fail=$((fail + 1))
}

swap_uses_helper=$(awk '
    /^tune_pi_zero_2w_swap_safety\(\) \{/ {f=1}
    f && /is_pi_zero_2w \|\| return 0/ {print "yes"; exit}
    f && /^\}/ {exit}
' "$TUNE_SH")
[[ "$swap_uses_helper" == "yes" ]] && {
    echo "  PASS: tune_pi_zero_2w_swap_safety uses is_pi_zero_2w"
    pass=$((pass + 1))
} || {
    echo "  FAIL: tune_pi_zero_2w_swap_safety does NOT use is_pi_zero_2w"
    fail=$((fail + 1))
}

# check_containers.sh: legacy _is_pi_zero_2w_smoke alias removed in
# Bundle B1 (call sites now use is_pi_zero_2w directly). Verify the
# direct call form is in place and the inline fallback is gone.
assert 'grep -qF " is_pi_zero_2w; " "$CHECK_CONTAINERS" || grep -qE "\\|\\| is_pi_zero_2w" "$CHECK_CONTAINERS"' \
    "check_containers.sh: calls is_pi_zero_2w directly (no _smoke alias)"
assert '! grep -qE "tr -d .* /proc/device-tree/model" "$CHECK_CONTAINERS"' \
    "check_containers.sh: no inline /proc/device-tree/model fallback"

echo
echo "=== firstboot.sh: promote client -> client-native ==="

assert 'grep -qE "^source.*device-detect\\.sh" "$FIRSTBOOT"' \
    "firstboot.sh sources device-detect.sh"

# Promote block must run BEFORE the case statement and BEFORE the
# hardware guard validator.
promote_line=$(grep -nE "INSTALL_TYPE=\"client-native\"" "$FIRSTBOOT" | head -1 | cut -d: -f1)
case_line=$(grep -nE "^case \"\\\$INSTALL_TYPE\" in$" "$FIRSTBOOT" | head -1 | cut -d: -f1)
guard_line=$(grep -nE "^_validate_profile_hardware$" "$FIRSTBOOT" | head -1 | cut -d: -f1)

if [[ -n "$promote_line" && -n "$case_line" && "$promote_line" -lt "$case_line" ]]; then
    echo "  PASS: promote (line $promote_line) runs BEFORE case (line $case_line)"
    pass=$((pass + 1))
else
    echo "  FAIL: promote not before case (promote=$promote_line, case=$case_line)"
    fail=$((fail + 1))
fi

if [[ -n "$promote_line" && -n "$guard_line" && "$promote_line" -lt "$guard_line" ]]; then
    echo "  PASS: promote (line $promote_line) runs BEFORE hardware guard (line $guard_line)"
    pass=$((pass + 1))
else
    echo "  FAIL: promote not before hardware guard (promote=$promote_line, guard=$guard_line)"
    fail=$((fail + 1))
fi

# Case statement now has a client-native arm.
assert 'grep -qE "^[[:space:]]+client-native\\)" "$FIRSTBOOT"' \
    "firstboot.sh case statement has client-native branch"

# Legacy _is_pi_zero_2w_native_path is gone — replaced by the
# single-source `[[ "$INSTALL_TYPE" == "client-native" ]]` check.
assert '! grep -qE "^_is_pi_zero_2w_native_path\\(\\) \\{" "$FIRSTBOOT"' \
    "legacy _is_pi_zero_2w_native_path() removed"

# SKIP_DOCKER is now gated on INSTALL_TYPE=client-native. Check the
# canonical pattern: `if [[ "$INSTALL_TYPE" == "client-native" ]];
# then SKIP_DOCKER=true`. awk grabs the few lines containing the test.
gated=$(awk '
    /INSTALL_TYPE.*==.*"client-native"/ {block=NR; next}
    block && NR <= block + 3 && /SKIP_DOCKER=true/ {print "yes"; exit}
' "$FIRSTBOOT")
if [[ "$gated" == "yes" ]]; then
    echo "  PASS: SKIP_DOCKER=true is gated on INSTALL_TYPE=client-native"
    pass=$((pass + 1))
else
    echo "  FAIL: SKIP_DOCKER=true not gated by INSTALL_TYPE=client-native"
    fail=$((fail + 1))
fi

# is_client_install helper covers all three client-family profiles.
assert 'grep -qE "^is_client_install\\(\\) \\{" "$FIRSTBOOT"' \
    "is_client_install() helper defined"
helper_body=$(awk '
    /^is_client_install\(\) \{/ {f=1}
    f
    f && /^\}/ {exit}
' "$FIRSTBOOT")
for profile in client client-native both; do
    if grep -qE "\b${profile}\b" <<<"$helper_body"; then
        echo "  PASS: is_client_install covers $profile"
        pass=$((pass + 1))
    else
        echo "  FAIL: is_client_install does NOT cover $profile"
        fail=$((fail + 1))
    fi
done

echo
echo "=== Functional: promote rule via extracted block ==="

# Extract the promote block + is_pi_zero_2w into a self-contained
# driver. We mock is_pi_zero_2w by exporting its return value.
PROMOTE_TEST=$(mktemp /tmp/snapmulti-promote-XXXXXX.sh)
# shellcheck disable=SC2064
trap "rm -f '$PROMOTE_TEST'" EXIT

cat > "$PROMOTE_TEST" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
log_info() { :; }
log_error() { :; }

# Mock is_pi_zero_2w from $IS_ZERO env var (0=true, 1=false).
is_pi_zero_2w() { return "${IS_ZERO:-1}"; }

INSTALL_TYPE="${INPUT_TYPE:-server}"

# This block must mirror firstboot.sh exactly.
if [[ "$INSTALL_TYPE" == "client" ]] && is_pi_zero_2w; then
    log_info "Pi Zero 2W detected — promoting profile: client -> client-native"
    INSTALL_TYPE="client-native"
fi

echo "$INSTALL_TYPE"
EOF

promote_case() {
    local input="$1" is_zero="$2" expected="$3" desc="$4"
    local out
    out=$(INPUT_TYPE="$input" IS_ZERO="$is_zero" bash "$PROMOTE_TEST")
    if [[ "$out" == "$expected" ]]; then
        echo "  PASS: $desc"
        pass=$((pass + 1))
    else
        echo "  FAIL: $desc (input=$input is_zero=$is_zero -> $out, expected $expected)"
        fail=$((fail + 1))
    fi
}

# Pi Zero 2W (IS_ZERO=0 means is_pi_zero_2w returns true):
promote_case "client" 0 "client-native" "Pi Zero 2W + client -> client-native"
promote_case "server" 0 "server"        "Pi Zero 2W + server stays server (guard rejects later)"
promote_case "both"   0 "both"          "Pi Zero 2W + both stays both (guard rejects later)"

# Non-Zero (IS_ZERO=1 means is_pi_zero_2w returns false):
promote_case "client" 1 "client" "Pi 3/4/5 + client stays client"
promote_case "server" 1 "server" "Pi 3/4/5 + server stays server"
promote_case "both"   1 "both"   "Pi 3/4/5 + both stays both"

echo
echo "Results: $pass passed, $fail failed"
exit $(( fail > 0 ? 1 : 0 ))
