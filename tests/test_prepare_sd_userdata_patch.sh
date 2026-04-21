#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PREPARE_SD_SH="$SCRIPT_DIR/../scripts/prepare-sd.sh"

pass=0
fail=0

assert_contains() {
    local file="$1" needle="$2" desc="$3"
    if grep -qF "$needle" "$file"; then
        echo "  PASS: $desc"
        pass=$((pass + 1))
    else
        echo "  FAIL: $desc (missing '$needle')"
        fail=$((fail + 1))
    fi
}

assert_not_contains() {
    local file="$1" needle="$2" desc="$3"
    if grep -qF "$needle" "$file"; then
        echo "  FAIL: $desc (found '$needle')"
        fail=$((fail + 1))
    else
        echo "  PASS: $desc"
        pass=$((pass + 1))
    fi
}

eval "$(sed -n '/^patch_user_data_runcmd()/,/^}/p' "$PREPARE_SD_SH")"

echo "Testing prepare-sd user-data patching..."

run_case() {
    local name="$1" content="$2"
    local tmp
    tmp=$(mktemp)
    printf '%s\n' "$content" > "$tmp"
    patch_user_data_runcmd "$tmp" "/boot/firmware/snapmulti/firstboot.sh"
    echo "$tmp"
}

tmp1=$(run_case "plain-runcmd" $'#cloud-config\nruncmd:\n  - [ sh, -c, echo first ]')
assert_contains "$tmp1" '  - [bash, /boot/firmware/snapmulti/firstboot.sh]' "plain runcmd gets hook"

tmp2=$(run_case "inline-empty" $'#cloud-config\nruncmd: []')
assert_contains "$tmp2" 'runcmd:' "inline [] converted to block key"
assert_contains "$tmp2" '  - [bash, /boot/firmware/snapmulti/firstboot.sh]' "inline [] gets hook"
assert_not_contains "$tmp2" 'runcmd: []' "inline [] removed"

tmp3=$(run_case "inline-null" $'#cloud-config\nruncmd: null')
assert_contains "$tmp3" 'runcmd:' "inline null converted to block key"
assert_contains "$tmp3" '  - [bash, /boot/firmware/snapmulti/firstboot.sh]' "inline null gets hook"
assert_not_contains "$tmp3" 'runcmd: null' "inline null removed"

tmp4=$(run_case "indented" $'#cloud-config\n  runcmd:\n    - [ sh, -c, echo first ]')
assert_contains "$tmp4" '  runcmd:' "indented runcmd preserved"
assert_contains "$tmp4" '    - [bash, /boot/firmware/snapmulti/firstboot.sh]' "indented hook matches indentation"

rm -f "$tmp1" "$tmp2" "$tmp3" "$tmp4"

echo ""
if [[ "$fail" -gt 0 ]]; then
    echo "FAILED: $fail tests failed, $pass passed"
    exit 1
fi
echo "All $pass tests passed!"
