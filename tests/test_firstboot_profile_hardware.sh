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

# Validator body must check Zero 2 W AND reject server|both.
validator_body=$(awk '
    /^_validate_profile_hardware\(\) \{/ {f=1}
    f
    f && /^\}/ {f=0}
' "$FIRSTBOOT")

assert_contains "$validator_body" "Zero 2 W" "validator checks model 'Zero 2 W'"
assert_contains "$validator_body" "server|both" "validator rejects server|both in case"
assert_contains "$validator_body" "exit 1" "validator exits non-zero on reject"
assert_contains "$validator_body" "/proc/device-tree/model" "validator reads /proc/device-tree/model"

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
EOF

awk '
    /^_validate_profile_hardware\(\) \{/ {f=1}
    f {print}
    f && /^\}/ {exit}
' "$FIRSTBOOT" >> "$EXTRACT"

# Make /proc/device-tree controllable via env var by stubbing the model
# read with a `cat` of $MOCK_MODEL_FILE if set.
# Approach: rewrite the function to read from $MOCK_MODEL_FILE if non-empty.
# We use a sed replacement after the extract so the test stays
# isolated from production code paths.
sed -i.bak '
    s|tr -d .\\0. </proc/device-tree/model 2>/dev/null|tr -d "\\0" <"${MOCK_MODEL_FILE:-/proc/device-tree/model}" 2>/dev/null|
' "$EXTRACT" 2>/dev/null || {
    # macOS BSD sed wants -i ''
    sed -i '' '
        s|tr -d .\\0. </proc/device-tree/model 2>/dev/null|tr -d "\\0" <"${MOCK_MODEL_FILE:-/proc/device-tree/model}" 2>/dev/null|
    ' "$EXTRACT"
}
rm -f "${EXTRACT}.bak"
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
