#!/usr/bin/env bash
# Static + functional checks for _validate_profile_hardware() in
# scripts/firstboot.sh.
#
# Invariants we guard:
#   1. The validator exists and is called BEFORE the case statement (so
#      we exit before any irreversible work).
#   2. Pi Zero 2W + INSTALL_TYPE=server -> exit 1 with a clear message.
#   3. Pi Zero 2W + INSTALL_TYPE=both   -> exit 1 with a clear message.
#   4. Pi Zero 2W + INSTALL_TYPE=client -> no-op (the native client
#      install is the supported mode).
#   5. Non-Zero-2W models pass for every INSTALL_TYPE (server/client/both).
#   6. /proc/device-tree/model unreadable -> no-op (do not block install
#      in CI / container test environments where /proc/device-tree is
#      absent or empty; the worst case is the legacy "tries Docker and
#      fails late" path, which is what we have today).

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

echo "=== Static checks ==="

assert '[[ -f "$FIRSTBOOT" ]]' "firstboot.sh exists"
assert 'bash -n "$FIRSTBOOT"' "firstboot.sh: bash -n clean"

assert 'grep -qE "^_validate_profile_hardware\\(\\) \\{" "$FIRSTBOOT"' \
       "_validate_profile_hardware() defined"
assert 'grep -qE "^_validate_profile_hardware\$" "$FIRSTBOOT"' \
       "_validate_profile_hardware called (not just defined)"

# install-profile.sh must be sourced so the validator + the
# install_profile_resolve / install_profile_is_valid gate can run.
assert 'grep -qE "source \"\\\$COMMON/install-profile.sh\"" "$FIRSTBOOT"' \
       "firstboot.sh sources install-profile.sh"

# Per the contract documented in scripts/common/install-profile.sh,
# firstboot MUST: (a) resolve the type (apply Pi Zero promotion),
# (b) gate on install_profile_is_valid + exit 1 on rejection,
# (c) THEN branch on predicates. Predicates return false silently on
# invalid types — without the gate a malformed install.conf silently
# does nothing and reports success.
resolve_line=$(grep -nE "install_profile_resolve" "$FIRSTBOOT" | head -1 | cut -d: -f1)
gate_line=$(grep -nE "install_profile_is_valid" "$FIRSTBOOT" | head -1 | cut -d: -f1)
validator_def_line=$(grep -nE "^_validate_profile_hardware\(\) \{" "$FIRSTBOOT" | head -1 | cut -d: -f1)
if [[ -n "$resolve_line" && -n "$gate_line" && "$resolve_line" -lt "$gate_line" ]]; then
    echo "  PASS: install_profile_resolve (line $resolve_line) runs BEFORE install_profile_is_valid gate (line $gate_line)"
    pass=$((pass + 1))
else
    echo "  FAIL: resolve must precede is_valid gate (resolve=$resolve_line, gate=$gate_line)"
    fail=$((fail + 1))
fi
if [[ -n "$gate_line" && -n "$validator_def_line" && "$gate_line" -lt "$validator_def_line" ]]; then
    echo "  PASS: install_profile_is_valid gate (line $gate_line) runs BEFORE _validate_profile_hardware (line $validator_def_line)"
    pass=$((pass + 1))
else
    echo "  FAIL: is_valid gate must precede validator (gate=$gate_line, validator=$validator_def_line)"
    fail=$((fail + 1))
fi

# Validator MUST run before the case statement so we exit cheaply.
validator_line=$(grep -nE "^_validate_profile_hardware\$" "$FIRSTBOOT" | head -1 | cut -d: -f1)
case_line=$(grep -nE "^case \"\\\$INSTALL_TYPE\" in\$" "$FIRSTBOOT" | head -1 | cut -d: -f1)
if [[ -n "$validator_line" && -n "$case_line" && "$validator_line" -lt "$case_line" ]]; then
    echo "  PASS: _validate_profile_hardware (line $validator_line) runs BEFORE case (line $case_line)"
    pass=$((pass + 1))
else
    echo "  FAIL: validator not before case (validator=$validator_line, case=$case_line)"
    fail=$((fail + 1))
fi

# Validator body must call is_pi_zero_2w (NOT inline /proc/device-tree
# read) and reject server|both. Bundle B1 moved the detection into
# scripts/common/device-detect.sh as the single authority.
validator_body=$(awk '
    /^_validate_profile_hardware\(\) \{/ {f=1}
    f
    f && /^\}/ {f=0}
' "$FIRSTBOOT")

assert_contains "$validator_body" "install_profile_hardware_ok" "validator delegates to install_profile_hardware_ok (SSOT from install-profile.sh)"
assert_contains "$validator_body" "exit 1" "validator exits non-zero on reject"
# Static gate: no inline /proc/device-tree/model read inside the
# validator body (must route through device-detect.sh).
if grep -qF "/proc/device-tree/model" <<<"$validator_body"; then
    echo "  FAIL: validator reads /proc/device-tree/model inline — route via device-detect.sh"
    fail=$((fail + 1))
else
    echo "  PASS: validator has no inline /proc/device-tree/model read"
    pass=$((pass + 1))
fi

# Error message must point the user at the fix.
assert_contains "$validator_body" "Reflash this SD" "validator message tells user to reflash"
assert_contains "$validator_body" "INSTALL_TYPE=client" "validator message names the correct INSTALL_TYPE"
assert_contains "$validator_body" "docs/HARDWARE.md" "validator points at HARDWARE.md"

echo
echo "=== Functional: extract validator + drive with mock /proc/device-tree ==="

# Extract the function body to a temp file we can source standalone —
# the rest of firstboot.sh is not safe to source (it reads install.conf,
# patches cmdline.txt, etc.). awk grabs from the function header to the
# matching closing brace at column 0.
EXTRACT=$(mktemp /tmp/snapmulti-validator-XXXXXX.sh)
# shellcheck disable=SC2064  # intentional: $EXTRACT must expand NOW so
# the trap captures the specific tmpfile, not the variable name.
trap "rm -f '$EXTRACT'" EXIT

cat > "$EXTRACT" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail

# Stub the logger so we can capture error messages.
log_error() { echo "[ERROR] $*" >&2; }

# Stub the canonical detection helpers (from scripts/common/device-detect.sh)
# driven by $MOCK_MODEL_FILE — the validator now calls is_pi_zero_2w /
# device_model instead of reading /proc/device-tree/model inline.
_read_mock_model() {
    [[ -n "${MOCK_MODEL_FILE:-}" && -r "$MOCK_MODEL_FILE" ]] || return 0
    tr -d '\0' <"$MOCK_MODEL_FILE" 2>/dev/null || true
}
is_pi_zero_2w() {
    local m
    m=$(_read_mock_model)
    [[ "$m" == *"Zero 2 W"* ]]
}
device_model() { _read_mock_model; }
EOF

# Source install-profile.sh's predicate (the validator now delegates to
# install_profile_hardware_ok) into the extract so the standalone test
# exercises the real production code path, not a re-stub.
cat "$SCRIPT_DIR/../scripts/common/install-profile.sh" >> "$EXTRACT"

awk '
    /^_validate_profile_hardware\(\) \{/ {f=1}
    f {print}
    f && /^\}/ {exit}
' "$FIRSTBOOT" >> "$EXTRACT"

echo '_validate_profile_hardware' >> "$EXTRACT"

run_case() {
    local model="$1" install_type="$2" expect_rc="$3" desc="$4"
    local model_file
    model_file=$(mktemp /tmp/snapmulti-model-XXXXXX)
    printf '%s' "$model" > "$model_file"

    local rc=0
    MOCK_MODEL_FILE="$model_file" INSTALL_TYPE="$install_type" \
        bash "$EXTRACT" >/dev/null 2>&1 || rc=$?

    rm -f "$model_file"

    if [[ "$rc" == "$expect_rc" ]]; then
        echo "  PASS: $desc"
        pass=$((pass + 1))
    else
        echo "  FAIL: $desc (got rc=$rc, expected $expect_rc)"
        fail=$((fail + 1))
    fi
}

echo
# Pi Zero 2W -> server/both rejected, client allowed.
run_case "Raspberry Pi Zero 2 W Rev 1.0" "server" 1 \
    "Pi Zero 2W + server is rejected (exit 1)"
run_case "Raspberry Pi Zero 2 W Rev 1.0" "both" 1 \
    "Pi Zero 2W + both is rejected (exit 1)"
run_case "Raspberry Pi Zero 2 W Rev 1.0" "client" 0 \
    "Pi Zero 2W + client is allowed (exit 0)"

# Other Pi models accept every profile.
for model in "Raspberry Pi 4 Model B Rev 1.4" "Raspberry Pi 3 Model B Plus Rev 1.3" "Raspberry Pi 5 Model B Rev 1.0"; do
    for profile in client server both; do
        run_case "$model" "$profile" 0 \
            "$(echo "$model" | awk '{print $3, $4, $5}') + $profile is allowed"
    done
done

# /proc/device-tree/model unreadable -> no-op.
run_case "" "server" 0 \
    "empty model file -> validator does not block server install (CI safety)"
run_case "" "both" 0 \
    "empty model file -> validator does not block both install (CI safety)"

# Verify the rejection message is the one we want users to see.
out=$(MOCK_MODEL_FILE=<(echo -n "Raspberry Pi Zero 2 W Rev 1.0") \
      INSTALL_TYPE=server bash "$EXTRACT" 2>&1 >/dev/null || true)
assert_contains "$out" "512 MB RAM" "rejection message mentions the RAM constraint"
assert_contains "$out" "Reflash this SD with INSTALL_TYPE=client" "rejection message tells user how to recover"

echo
echo "Results: $pass passed, $fail failed"
exit $(( fail > 0 ? 1 : 0 ))
