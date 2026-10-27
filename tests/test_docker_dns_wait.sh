#!/usr/bin/env bash
# setup_docker installs a docker.service drop-in that waits (bounded) for a
# nameserver: host-network containers keep the /etc/resolv.conf copy taken
# at their start, and NetworkManager-wait-online is masked on the Pi.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SETUP_DOCKER_SH="$SCRIPT_DIR/../scripts/common/setup-docker.sh"

pass=0
fail=0
check() {
    local desc="$1"; shift
    if "$@"; then
        echo "  PASS: $desc"; pass=$((pass + 1))
    else
        echo "  FAIL: $desc"; fail=$((fail + 1))
    fi
}

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
dropin="$tmp/docker.service.d/snapmulti-wait-dns.conf"

echo "Testing docker.service DNS wait drop-in..."

# Docker already installed, writable root: the early-return path.
(
    export DOCKER_DNS_WAIT_DROPIN="$dropin"
    # shellcheck source=../scripts/common/setup-docker.sh
    source "$SETUP_DOCKER_SH"
    docker() { return 0; }
    findmnt() { echo ext4; }
    systemctl() { echo "systemctl $*" >> "$tmp/calls"; }
    setup_docker >/dev/null 2>&1
)

check "drop-in written by setup_docker when Docker is already installed" test -f "$dropin"
exec_line=$(grep '^ExecStartPre=' "$dropin" 2>/dev/null || true)
check "drop-in is a [Service] section" grep -qx '\[Service\]' "$dropin"
check "wait is bounded by timeout and cannot fail the start" \
    grep -qE '^ExecStartPre=-/usr/bin/timeout [0-9]+ ' <<<"$exec_line"
check "waits for a nameserver line in /etc/resolv.conf" \
    grep -qF '"^nameserver" /etc/resolv.conf' <<<"$exec_line"
check "no '\$' in the command (systemd would expand it)" \
    bash -c '! grep -qF "\$" <<<"$1"' _ "$exec_line"
check "systemd reloaded after writing the drop-in" grep -qx 'systemctl daemon-reload' "$tmp/calls"

# The command itself: returns at once with a nameserver, gives up when bounded.
cmd=${exec_line#ExecStartPre=-/usr/bin/timeout 20 /bin/sh -c }
cmd=${cmd#\'}; cmd=${cmd%\'}
printf 'nameserver 192.0.2.1\n' > "$tmp/resolv.ok"
: > "$tmp/resolv.empty"
check "command returns at once when a nameserver exists" \
    timeout 3 /bin/sh -c "${cmd//\/etc\/resolv.conf/$tmp/resolv.ok}"
check "command keeps waiting while resolv.conf has no nameserver" \
    bash -c '! timeout 2 /bin/sh -c "$1"' _ "${cmd//\/etc\/resolv.conf/$tmp/resolv.empty}"

echo ""
if [[ "$fail" -gt 0 ]]; then
    echo "FAILED: $fail tests failed, $pass passed"
    exit 1
fi
echo "All $pass tests passed"
