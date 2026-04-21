#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FIRSTBOOT_SH="$SCRIPT_DIR/../scripts/firstboot.sh"
PS1_FILE="$SCRIPT_DIR/../scripts/prepare-sd.ps1"

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

firstboot_content="$(cat "$FIRSTBOOT_SH")"
ps1_content="$(cat "$PS1_FILE")"

echo "Testing SMB user sanitization parity..."

assert_contains "$firstboot_content" 'SMB_USER=$(sanitize_smb_user' "firstboot sanitizes SMB_USER on read"
assert_contains "$ps1_content" 'function Sanitize-SmbUser' "prepare-sd.ps1 defines SMB username sanitizer"
assert_contains "$ps1_content" '$user = Sanitize-SmbUser $rawUser' "prepare-sd.ps1 sanitizes SMB username input"

echo ""
if [[ "$fail" -gt 0 ]]; then
    echo "FAILED: $fail tests failed, $pass passed"
    exit 1
fi
echo "All $pass tests passed!"
