#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_SH="$SCRIPT_DIR/../scripts/deploy.sh"
SNIPPETS_SH="$SCRIPT_DIR/../scripts/common/systemd-snippets.sh"

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

# Source-text checks (function wiring, idempotency markers).
service_body="$(sed -n '/^install_systemd_service()/,/^}/p' "$DEPLOY_SH")"

# Rendered unit-file checks (the actual content systemd will read).
# Mirrors the render_unit pattern in test_avahi_readiness.sh — sources
# systemd-snippets.sh so $(helper) substitutions inside the heredoc
# resolve to the final unit-file lines.
# shellcheck source=../scripts/common/systemd-snippets.sh
source "$SNIPPETS_SH"
heredoc_body=$(awk '
    $0 ~ ("cat > /etc/systemd/system/snapmulti-server.service *<< *EOF") {flag=1; next}
    flag && /^EOF$/ {flag=0; exit}
    flag {print}
' "$DEPLOY_SH")
PROJECT_ROOT=/opt/snapmulti
# shellcheck disable=SC2034  # consumed inside eval'd heredoc below
music_mount_clause=""
service_unit=$(eval "cat <<EOF
$heredoc_body
EOF")

echo "Testing deploy systemd service..."

assert_contains "$service_body" 'snapmulti-server.service' "service file is created"
assert_contains "$service_unit" 'ExecStart=/usr/bin/docker compose up -d' "service starts compose stack"
assert_contains "$service_unit" 'ExecStop=/usr/bin/docker compose stop -t 5' "service stops compose stack non-destructively"
assert_contains "$service_unit" "WorkingDirectory=$PROJECT_ROOT" "service runs from project root"
assert_contains "$service_unit" 'WantedBy=multi-user.target' "service is enabled at boot"
assert_contains "$service_body" 'systemctl enable snapmulti-server.service' "service is enabled"

echo ""
if [[ "$fail" -gt 0 ]]; then
    echo "FAILED: $fail tests failed, $pass passed"
    exit 1
fi
echo "All $pass tests passed!"
