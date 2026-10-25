#!/usr/bin/env bash
# Tests for install_server_discovery (scripts/common/system-tune.sh):
#   - publishes the landing page (metadata HTTP, port 8083) as an Avahi
#     `_http._tcp` service "snapMULTI on %h"
#   - adds /etc/issue.d/snapmulti.issue with agetty escapes for the
#     hostname (\n) and IPv4 address (\4), ASCII only (framebuffer font)
#   - idempotent: a second run rewrites nothing and does not reload Avahi
#   - skips the Avahi file when avahi is not installed
#   - wired into deploy.sh (server installs) and nowhere in the client
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$SCRIPT_DIR/.."

# shellcheck source=../scripts/common/system-tune.sh
source "$ROOT/scripts/common/system-tune.sh"

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

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/stubs" "$TMP/avahi/services"
cat > "$TMP/stubs/systemctl" <<'EOF'
#!/bin/sh
echo "$*" >> "$STATE_DIR/systemctl.calls"
EOF
chmod +x "$TMP/stubs/systemctl"
export STATE_DIR="$TMP"
export PATH="$TMP/stubs:$PATH"
export AVAHI_SERVICES_DIR="$TMP/avahi/services"
export ISSUE_D_DIR="$TMP/issue.d"
SVC="$AVAHI_SERVICES_DIR/snapmulti-http.service"
ISSUE="$ISSUE_D_DIR/snapmulti.issue"

echo "## First run"
install_server_discovery >/dev/null
assert "[[ -f '$SVC' ]]" "Avahi service file written"
assert "grep -q '<type>_http._tcp</type>' '$SVC'" "service type _http._tcp"
assert "grep -q '<port>8083</port>' '$SVC'" "port 8083 (metadata-service landing page)"
assert "grep -q 'replace-wildcards=\"yes\">snapMULTI on %h</name>' '$SVC'" "name 'snapMULTI on %h' with wildcard expansion"
if command -v xmllint >/dev/null 2>&1; then
    assert "xmllint --noout '$SVC' 2>/dev/null" "service file is well-formed XML"
fi
assert "grep -q 'reload avahi-daemon' '$TMP/systemctl.calls'" "Avahi reloaded (not restarted) after the change"
assert "! grep -q 'restart' '$TMP/systemctl.calls'" "no avahi restart (would drop snapcast's libavahi-client)"
assert "[[ -f '$ISSUE' ]]" "issue.d hint written"
assert "grep -qF 'http://\\n.local:8083/' '$ISSUE'" "hint uses agetty \\n (hostname) escape"
assert "grep -qF 'http://\\4:8083/' '$ISSUE'" "hint uses agetty \\4 (IPv4) escape"
assert "! LC_ALL=C grep -q '[^ -~]' '$ISSUE'" "hint is printable ASCII only (framebuffer PSF font)"

echo
echo "## Second run is a no-op"
svc_before=$(stat -c '%Y %i' "$SVC"); issue_before=$(stat -c '%Y %i' "$ISSUE")
: > "$TMP/systemctl.calls"
sleep 1
install_server_discovery >/dev/null
assert "[[ \"\$(stat -c '%Y %i' '$SVC')\" == \"\$svc_before\" ]]" "service file not rewritten"
assert "[[ \"\$(stat -c '%Y %i' '$ISSUE')\" == \"\$issue_before\" ]]" "issue file not rewritten"
assert "[[ ! -s '$TMP/systemctl.calls' ]]" "no Avahi reload when nothing changed"

echo
echo "## Avahi not installed"
rm -rf "$TMP/avahi"
install_server_discovery >/dev/null
assert "[[ ! -e '$SVC' ]]" "no service file (and no services dir created) without avahi"

echo
echo "## Wiring"
assert "awk '/^setup_server_host\\(\\)/,/^}/' '$ROOT/scripts/deploy.sh' | grep -q '^ *install_server_discovery$'" \
    "deploy.sh setup_server_host installs it (server + both installs)"
assert "! grep -rq 'install_server_discovery' '$ROOT/client'" "client installer never publishes the server service"

echo
echo "## Summary"
echo "  Passed: $pass"
echo "  Failed: $fail"
[[ $fail -eq 0 ]]
