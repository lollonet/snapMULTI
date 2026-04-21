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
deploy_body="$(sed -n '/^install_dependencies()/,/^}/p' "$DEPLOY_SH")"

echo "Testing host dependency coverage..."

assert_contains "$common_body" "local pkgs=(curl ca-certificates python3 netcat-openbsd)" "shared install-deps always includes python3 and netcat"
assert_contains "$deploy_body" "command -v python3" "deploy checks for python3 explicitly"
assert_contains "$deploy_body" "apt-get install -y -qq python3" "deploy installs python3 when missing"
assert_contains "$deploy_body" "command -v nc" "deploy checks for netcat explicitly"
assert_contains "$deploy_body" "apt-get install -y -qq netcat-openbsd" "deploy installs netcat when missing"

echo ""
if [[ "$fail" -gt 0 ]]; then
    echo "FAILED: $fail tests failed, $pass passed"
    exit 1
fi
echo "All $pass tests passed!"
