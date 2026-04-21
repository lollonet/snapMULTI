#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISCOVER_SH="$SCRIPT_DIR/../common/scripts/discover-server.sh"

pass=0
fail=0

assert_eq() {
    local actual="$1" expected="$2" desc="$3"
    if [[ "$actual" == "$expected" ]]; then
        echo "  PASS: $desc"
        pass=$((pass + 1))
    else
        echo "  FAIL: $desc (got '$actual', expected '$expected')"
        fail=$((fail + 1))
    fi
}

_write_server() {
    local host="$1"
    printf 'SNAPSERVER_HOST=%s\n' "$host" > "$ENV_FILE"
}

_restart_stack() {
    grep '^SNAPSERVER_HOST=' "$ENV_FILE" | cut -d= -f2 > "$LOG_FILE"
    return "${RESTART_RC:-0}"
}

_apply_server_change() {
    local new_host="$1"
    local current
    current=$(grep "^SNAPSERVER_HOST=" "$ENV_FILE" 2>/dev/null | cut -d= -f2) || true
    if [[ "$new_host" != "$current" ]]; then
        _write_server "$new_host"
        echo "$new_host" > "$LAST_IP_FILE"
        if [[ "${WATCH_MODE:-false}" == "true" ]]; then
            _restart_stack || return 2
        fi
        return 0
    fi
    return 1
}

echo "Testing discover-server restart ordering..."

test_apply_change() {
    local initial="$1" new_host="$2" watch_mode="$3" restart_rc="$4" expected_rc="$5" expected_host="$6" desc="$7"
    local tmpdir env_file ip_file log_file
    tmpdir=$(mktemp -d)
    env_file="$tmpdir/.env"
    ip_file="$tmpdir/last-ip"
    log_file="$tmpdir/restart.log"

    printf 'SNAPSERVER_HOST=%s\n' "$initial" > "$env_file"

    ENV_FILE="$env_file"
    LAST_IP_FILE="$ip_file"
    WATCH_MODE="$watch_mode"
    LOG_FILE="$log_file"
    RESTART_RC="$restart_rc"

    local rc=0 current restarted_with
    _apply_server_change "$new_host" || rc=$?
    current=$(grep '^SNAPSERVER_HOST=' "$env_file" | cut -d= -f2)
    restarted_with="$(cat "$log_file" 2>/dev/null || echo '')"

    assert_eq "$rc" "$expected_rc" "$desc: return code"
    assert_eq "$current" "$expected_host" "$desc: .env updated"
    if [[ "$watch_mode" == "true" ]]; then
        assert_eq "$restarted_with" "$expected_host" "$desc: restart sees new host"
    fi

    rm -rf "$tmpdir"
}

test_apply_change "10.0.0.5" "127.0.0.1" "true" 0 0 "127.0.0.1" "both mode change"
test_apply_change "10.0.0.5" "192.168.1.20" "true" 0 0 "192.168.1.20" "mDNS host change"
test_apply_change "10.0.0.5" "127.0.0.1" "true" 1 2 "127.0.0.1" "restart failure preserves updated host"

echo ""
if [[ "$fail" -gt 0 ]]; then
    echo "FAILED: $fail tests failed, $pass passed"
    exit 1
fi
echo "All $pass tests passed!"
