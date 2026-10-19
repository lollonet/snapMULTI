#!/usr/bin/env bash
# Docker CE apt suite selection in scripts/common/install-docker.sh.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DOCKER_SH="$SCRIPT_DIR/../scripts/common/install-docker.sh"

pass=0
fail=0

assert_eq() {
    local actual="$1" expected="$2" desc="$3"
    if [[ "$actual" == "$expected" ]]; then
        echo "  PASS: $desc"
        pass=$((pass + 1))
    else
        echo "  FAIL: $desc (expected '$expected', got '$actual')"
        fail=$((fail + 1))
    fi
}

# shellcheck source=../scripts/common/install-docker.sh
source "$INSTALL_DOCKER_SH"

echo "Testing Docker repo suite per Debian codename..."

assert_eq "$(docker_repo_codename trixie)" "trixie" "trixie uses the trixie suite"
assert_eq "$(docker_repo_codename bookworm)" "bookworm" "bookworm uses the bookworm suite"
assert_eq "$(docker_repo_codename bullseye)" "bullseye" "bullseye uses the bullseye suite"
assert_eq "$(docker_repo_codename forky)" "trixie" "unpublished codename uses the newest suite"
assert_eq "$(docker_repo_codename "")" "trixie" "empty codename uses the newest suite"

setup_body="$(sed -n '/^setup_docker_repo()/,/^}/p' "$INSTALL_DOCKER_SH")"
if grep -qF 'docker_codename=$(docker_repo_codename ' <<<"$setup_body"; then
    echo "  PASS: setup_docker_repo picks the suite via docker_repo_codename"
    pass=$((pass + 1))
else
    echo "  FAIL: setup_docker_repo does not call docker_repo_codename"
    fail=$((fail + 1))
fi
if grep -q 'bookworm' <<<"$setup_body"; then
    echo "  FAIL: setup_docker_repo still hardcodes bookworm"
    fail=$((fail + 1))
else
    echo "  PASS: setup_docker_repo has no hardcoded bookworm"
    pass=$((pass + 1))
fi

echo ""
echo "Results: $pass passed, $fail failed"
[[ $fail -eq 0 ]]
