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

service_body="$(sed -n '/^install_systemd_service()/,/^}/p' "$DEPLOY_SH")"

echo "Testing deploy systemd service..."

assert_contains "$service_body" 'snapmulti-server.service' "service file is created"
assert_contains "$service_body" 'ExecStart=/usr/bin/docker compose up -d' "service starts compose stack"
assert_contains "$service_body" 'ExecStop=/usr/bin/docker compose down' "service stops compose stack"
assert_contains "$service_body" 'WorkingDirectory=${PROJECT_ROOT}' "service runs from project root"
assert_contains "$service_body" 'WantedBy=multi-user.target' "service is enabled at boot"
assert_contains "$service_body" 'systemctl enable snapmulti-server.service' "service is enabled"

echo ""
if [[ "$fail" -gt 0 ]]; then
    echo "FAILED: $fail tests failed, $pass passed"
    exit 1
fi
echo "All $pass tests passed!"
