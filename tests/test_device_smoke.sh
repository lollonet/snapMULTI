#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SMOKE_SH="$SCRIPT_DIR/../scripts/device-smoke.sh"

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

assert_rc() {
    local actual="$1" expected="$2" desc="$3"
    if [[ "$actual" == "$expected" ]]; then
        echo "  PASS: $desc"
        pass=$((pass + 1))
    else
        echo "  FAIL: $desc (got $actual, expected $expected)"
        fail=$((fail + 1))
    fi
}

MOCK_BIN="$(mktemp -d)"
TMP_SERVER="$(mktemp -d)"
TMP_CLIENT="$(mktemp -d)"
trap 'rm -rf "$MOCK_BIN" "$TMP_SERVER" "$TMP_CLIENT"' EXIT

touch "$TMP_SERVER/docker-compose.yml" "$TMP_CLIENT/docker-compose.yml"

cat > "$MOCK_BIN/docker" <<'MOCK'
#!/usr/bin/env bash
if [[ "$1" == "info" ]]; then
    echo "${MOCK_DOCKER_DRIVER:-overlayfs}"
    exit 0
fi
if [[ "$1" == "compose" ]]; then
    shift
    while [[ "${1:-}" == "-f" ]]; do shift 2; done
    case "${1:-} ${2:-} ${3:-}" in
        "config --services "*|"config --services ")
            case "${MOCK_STACK:-server}" in
                server) printf 'snapserver\nmpd\n' ;;
                client) printf 'snapclient\nfb-display\n' ;;
            esac
            ;;
        "config --format json")
            case "${MOCK_STACK:-server}" in
                server) printf '{"services":{"snapserver":{"healthcheck":{"test":["CMD","true"]}},"mpd":{"healthcheck":{"test":["CMD","true"]}}}}' ;;
                client) printf '{"services":{"snapclient":{"healthcheck":{"test":["CMD","true"]}},"fb-display":{"healthcheck":{"test":["CMD","true"]}}}}' ;;
            esac
            ;;
        "ps --status running")
            seq 1 "${MOCK_RUNNING:-2}" | sed 's/.*/id&/'
            ;;
        "ps -q "*|"ps -q ")
            case "${MOCK_STACK:-server}" in
                server) printf 'snapserver\nmpd\n' ;;
                client) printf 'snapclient\nfb-display\n' ;;
            esac
            ;;
    esac
    exit 0
fi
if [[ "$1" == "inspect" ]]; then
    shift
    if [[ "${1:-}" == "--format" ]]; then
        shift 2
    fi
    for arg in "$@"; do
        case "$arg" in
            snapserver|mpd|snapclient|fb-display)
                echo "healthy"
                ;;
            *)
                echo "healthy"
                ;;
        esac
    done
    exit 0
fi
exit 0
MOCK
chmod +x "$MOCK_BIN/docker"

cat > "$MOCK_BIN/systemctl" <<'MOCK'
#!/usr/bin/env bash
case "$1" in
    is-enabled|is-active) exit 0 ;;
esac
exit 0
MOCK
chmod +x "$MOCK_BIN/systemctl"

cat > "$MOCK_BIN/mount" <<'MOCK'
#!/usr/bin/env bash
if [[ "${MOCK_OVERLAY:-0}" == "1" ]]; then
    echo "overlayroot on / type overlay (rw,noatime)"
else
    echo "/dev/mmcblk0p2 on / type ext4 (rw,noatime)"
fi
MOCK
chmod +x "$MOCK_BIN/mount"

cat > "$MOCK_BIN/hostname" <<'MOCK'
#!/usr/bin/env bash
echo snapvideo
MOCK
chmod +x "$MOCK_BIN/hostname"

cat > "$MOCK_BIN/uptime" <<'MOCK'
#!/usr/bin/env bash
echo "up 5 minutes"
MOCK
chmod +x "$MOCK_BIN/uptime"

echo "Testing device-smoke.sh..."

output="$(
    PATH="$MOCK_BIN:$PATH" \
    MOCK_OVERLAY=1 \
    MOCK_DOCKER_DRIVER=fuse-overlayfs \
    MOCK_STACK=server \
    bash "$SMOKE_SH" --server --server-dir "$TMP_SERVER" 2>&1
)"
rc=$?
assert_rc "$rc" "0" "server mode passes with overlayroot + fuse-overlayfs"
assert_contains "$output" "Mode: server" "reports selected mode"
assert_contains "$output" "Smoke check passed" "reports passing summary"
assert_contains "$output" "server: 2/2 running, 2/2 healthy" "reports compose counts"

set +e
output="$(
    PATH="$MOCK_BIN:$PATH" \
    MOCK_OVERLAY=0 \
    MOCK_DOCKER_DRIVER=fuse-overlayfs \
    MOCK_STACK=client \
    bash "$SMOKE_SH" --client --client-dir "$TMP_CLIENT" 2>&1
)"
rc=$?
set -e
assert_rc "$rc" "1" "client mode fails on writable root + fuse-overlayfs"
assert_contains "$output" "writable root but Docker driver is fuse-overlayfs" "reports overlay mismatch"

echo ""
if [[ "$fail" -gt 0 ]]; then
    echo "FAILED: $fail tests failed, $pass passed"
    exit 1
fi
echo "All $pass tests passed!"
