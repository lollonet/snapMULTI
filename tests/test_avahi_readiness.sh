#!/usr/bin/env bash
# shellcheck disable=SC2016  # assert() conditions are eval'd inside the
#                              function — single quotes are intentional.
#
# Static checks for the avahi-daemon readiness fix.
#
# The bug: snapmulti-server.service (and snapclient.service) only waited
# for `docker info` readiness before `docker compose up -d`. When
# avahi-daemon was still initialising at that point, snapserver's
# libavahi-client connect race-lost — snapserver fell back to PTR-only
# UDP 5353 multicast. Strict mDNS clients (Python zeroconf, snapclient
# 0.36+) failed to discover the service.
#
# The fix:
#   1. Both units have a second ExecStartPre that polls
#      `systemctl is-active --quiet avahi-daemon.service` AND the socket
#      `/run/avahi-daemon/socket` for up to 30 s, then sleeps 2 s for
#      avahi's first announce.
#   2. snapmulti-server.service has an ExecStartPost self-heal: 12 s
#      after compose up, query avahi-browse for _snapcast._tcp; if PTR
#      is present but SRV/TXT are not, restart the snapserver container.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_SH="$SCRIPT_DIR/../scripts/deploy.sh"
SETUP_SH="$SCRIPT_DIR/../client/common/scripts/setup.sh"

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

echo "=== snapmulti-server.service — avahi readiness ExecStartPre ==="

# Extract the snapmulti-server unit file body from the heredoc.
server_unit=$(awk '/cat > \/etc\/systemd\/system\/snapmulti-server\.service/,/^EOF$/' "$DEPLOY_SH")

assert 'echo "$server_unit" | grep -qE "ExecStartPre=.*systemctl is-active --quiet avahi-daemon"' \
       'snapmulti-server has ExecStartPre gating on avahi-daemon is-active'

assert 'echo "$server_unit" | grep -qE "ExecStartPre=.*-S /run/avahi-daemon/socket"' \
       'snapmulti-server gates on /run/avahi-daemon/socket existence'

# Must NOT exit 1 — we want non-fatal fallthrough (avahi may be missing
# in unusual setups, the unit must still come up).
assert '! (echo "$server_unit" | grep -E "ExecStartPre.*avahi-daemon" | grep -qE "exit 1")' \
       'avahi readiness ExecStartPre is non-fatal (no exit 1)'

# Avahi-readiness ExecStartPre must come AFTER docker readiness one.
docker_line=$(echo "$server_unit" | grep -nE "ExecStartPre=.*docker info" | head -1 | cut -d: -f1)
avahi_line=$(echo "$server_unit" | grep -nE "ExecStartPre=.*avahi-daemon" | head -1 | cut -d: -f1)
if [[ -n "$docker_line" && -n "$avahi_line" && "$avahi_line" -gt "$docker_line" ]]; then
    echo "  PASS: avahi ExecStartPre runs AFTER docker readiness check"
    pass=$((pass + 1))
else
    echo "  FAIL: avahi ExecStartPre order wrong (docker=$docker_line, avahi=$avahi_line)"
    fail=$((fail + 1))
fi

echo
echo "=== snapmulti-server.service — mDNS self-heal ExecStartPost ==="

assert 'echo "$server_unit" | grep -qE "ExecStartPost"' \
       'snapmulti-server has an ExecStartPost hook'

assert 'echo "$server_unit" | grep -qE "avahi-browse.*_snapcast"' \
       'ExecStartPost queries avahi-browse for _snapcast._tcp'

assert 'echo "$server_unit" | grep -qE "docker compose.*restart snapserver"' \
       'ExecStartPost restarts snapserver on PTR-only detection'

# Self-heal must be ignore-failure (leading -) so a transient avahi-browse
# error never holds the unit in failed state.
assert 'echo "$server_unit" | grep -qE "ExecStartPost=-"' \
       'ExecStartPost is non-fatal (leading -)'

echo
echo "=== snapclient.service — avahi readiness ExecStartPre ==="

client_unit=$(awk '/cat > \/etc\/systemd\/system\/snapclient\.service/,/^EOF$/' "$SETUP_SH")

assert 'echo "$client_unit" | grep -qE "ExecStartPre=.*systemctl is-active --quiet avahi-daemon"' \
       'snapclient has ExecStartPre gating on avahi-daemon is-active'

assert 'echo "$client_unit" | grep -qE "ExecStartPre=.*-S /run/avahi-daemon/socket"' \
       'snapclient gates on /run/avahi-daemon/socket existence'

# Discover-server must run AFTER the avahi readiness wait — otherwise
# avahi-browse fired by snapclient-discover comes back empty. Filter by
# ExecStartPre prefix to avoid matching the explanatory comment.
avahi_cl=$(echo "$client_unit" | grep -nE "^ExecStartPre=.*avahi-daemon" | head -1 | cut -d: -f1)
discover_cl=$(echo "$client_unit" | grep -nE "^ExecStartPre=.*snapclient-discover" | head -1 | cut -d: -f1)
if [[ -n "$avahi_cl" && -n "$discover_cl" && "$avahi_cl" -lt "$discover_cl" ]]; then
    echo "  PASS: avahi readiness wait runs BEFORE snapclient-discover"
    pass=$((pass + 1))
else
    echo "  FAIL: snapclient-discover runs before avahi wait (avahi=$avahi_cl, discover=$discover_cl)"
    fail=$((fail + 1))
fi

echo
echo "=== Bash syntax ==="
for f in "$DEPLOY_SH" "$SETUP_SH"; do
    if bash -n "$f"; then
        echo "  PASS: bash -n $(basename "$f")"
        pass=$((pass + 1))
    else
        echo "  FAIL: bash -n $(basename "$f")"
        fail=$((fail + 1))
    fi
done

echo
echo "=== Summary ==="
echo "  Pass: $pass"
echo "  Fail: $fail"

[[ "$fail" -eq 0 ]]
