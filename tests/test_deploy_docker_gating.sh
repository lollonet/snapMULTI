#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
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

assert_not_contains() {
    local haystack="$1" needle="$2" desc="$3"
    if grep -qF -- "$needle" <<<"$haystack"; then
        echo "  FAIL: $desc (unexpected '$needle')"
        fail=$((fail + 1))
    else
        echo "  PASS: $desc"
        pass=$((pass + 1))
    fi
}

install_docker_body="$(sed -n '/^install_docker()/,/^}/p' "$DEPLOY_SH")"

echo "Testing deploy.sh Docker driver gating..."

assert_contains "$install_docker_body" "tune_docker_daemon --live-restore" "deploy configures live-restore"
assert_not_contains "$install_docker_body" "--fuse-overlayfs" "deploy does not force fuse-overlayfs"
assert_not_contains "$install_docker_body" "apt-get install -y fuse-overlayfs" "deploy does not install fuse-overlayfs eagerly"

echo ""
if [[ "$fail" -gt 0 ]]; then
    echo "FAILED: $fail tests failed, $pass passed"
    exit 1
fi
echo "All $pass tests passed!"
