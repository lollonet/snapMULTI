#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PREPARE_SD_SH="$SCRIPT_DIR/../scripts/prepare-sd.sh"

pass=0
fail=0

assert_contains() {
    local haystack="$1" needle="$2" desc="$3"
    if grep -qF "$needle" <<<"$haystack"; then
        echo "  PASS: $desc"
        pass=$((pass + 1))
    else
        echo "  FAIL: $desc (missing '$needle')"
        fail=$((fail + 1))
    fi
}

echo "Testing prepare-sd required file verification list..."

verify_block=$(sed -n '/for f in install.conf/,/^done/p' "$PREPARE_SD_SH")

assert_contains "$verify_block" "common/progress.sh" "progress.sh is required"
assert_contains "$verify_block" "common/logging.sh" "logging.sh is required"
assert_contains "$verify_block" "common/unified-log.sh" "unified-log.sh is required"
assert_contains "$verify_block" "common/install-docker.sh" "install-docker.sh is required"
assert_contains "$verify_block" "common/install-deps.sh" "install-deps.sh is required"
assert_contains "$verify_block" "common/setup-docker.sh" "setup-docker.sh is required"
assert_contains "$verify_block" "common/wait-network.sh" "wait-network.sh is required"
assert_contains "$verify_block" "common/mount-music.sh" "mount-music.sh is required"

echo ""
if [[ "$fail" -gt 0 ]]; then
    echo "FAILED: $fail tests failed, $pass passed"
    exit 1
fi
echo "All $pass tests passed!"
