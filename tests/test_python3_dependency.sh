#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMON_DEPS="$SCRIPT_DIR/../scripts/common/install-deps.sh"
DEPLOY_SH="$SCRIPT_DIR/../scripts/deploy.sh"

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

common_body="$(sed -n '/^install_dependencies()/,/^}/p' "$COMMON_DEPS")"
deploy_body="$(cat "$DEPLOY_SH")"

echo "Testing host dependency coverage..."

# Shared module has python3 and netcat in base packages
assert_contains "$common_body" "python3" "shared install-deps includes python3"
assert_contains "$common_body" "netcat-openbsd" "shared install-deps includes netcat"
assert_contains "$common_body" "avahi-daemon" "shared install-deps includes avahi-daemon"
assert_contains "$common_body" "avahi-browse" "shared install-deps checks avahi-browse (avahi-utils)"

# deploy.sh delegates to shared module instead of inline installs
assert_contains "$deploy_body" 'common/install-deps.sh' "deploy sources shared install-deps"
assert_contains "$deploy_body" "INSTALL_ROLE=server" "deploy sets server role"

echo ""
if [[ "$fail" -gt 0 ]]; then
    echo "FAILED: $fail tests failed, $pass passed"
    exit 1
fi
echo "All $pass tests passed!"
