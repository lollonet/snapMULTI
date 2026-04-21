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

# Extract production functions from discover-server.sh
# _update_server writes to ENV_FILE and LAST_IP_FILE (module-level vars)
eval "$(sed -n '/^_update_server()/,/^}/p' "$DISCOVER_SH")"

# macOS sed -i requires '' arg; production targets Linux (GNU sed).
# Wrap sed so -i works portably in test environment.
MOCK_BIN=$(mktemp -d)
trap 'rm -rf "$MOCK_BIN"' EXIT
REAL_SED=$(command -v sed)
cat > "$MOCK_BIN/sed" <<WRAPPER
#!/usr/bin/env bash
if [[ "\${1:-}" == "-i" ]]; then
    shift
    "$REAL_SED" -i '' "\$@"
else
    "$REAL_SED" "\$@"
fi
WRAPPER
chmod +x "$MOCK_BIN/sed"
export PATH="$MOCK_BIN:$PATH"

echo "Testing discover-server _update_server + restart ordering..."

test_update_and_restart() {
    local initial="$1" new_host="$2" do_restart="$3" restart_rc="$4" expected_rc="$5" expected_host="$6" desc="$7"
    local tmpdir
    tmpdir=$(mktemp -d)

    # Set module-level vars used by the eval'd _update_server function
    ENV_FILE="$tmpdir/.env"
    # shellcheck disable=SC2034  # used by eval'd _update_server
    LAST_IP_FILE="$tmpdir/last-ip"
    local log_file="$tmpdir/restart.log"

    printf 'SNAPSERVER_HOST=%s\n' "$initial" > "$ENV_FILE"

    # Simulate the production pattern: _update_server writes .env,
    # then caller restarts if in watch mode (same ordering as discover-server.sh:77-79)
    local rc=0
    if _update_server "$new_host"; then
        # .env updated — now simulate restart (reads .env like docker compose would)
        if [[ "$do_restart" == "true" ]]; then
            grep '^SNAPSERVER_HOST=' "$ENV_FILE" | cut -d= -f2 > "$log_file"
            (exit "$restart_rc") || rc=2
        fi
    else
        rc=1  # unchanged
    fi

    local current restarted_with
    current=$(grep '^SNAPSERVER_HOST=' "$ENV_FILE" | cut -d= -f2)
    restarted_with="$(cat "$log_file" 2>/dev/null || echo '')"

    assert_eq "$rc" "$expected_rc" "$desc: return code"
    assert_eq "$current" "$expected_host" "$desc: .env updated"
    if [[ "$do_restart" == "true" && "$rc" -ne 1 ]]; then
        assert_eq "$restarted_with" "$expected_host" "$desc: restart sees new host"
    fi

    rm -rf "$tmpdir"
}

test_update_and_restart "10.0.0.5" "127.0.0.1" "true"  0 0 "127.0.0.1"    "both mode change"
test_update_and_restart "10.0.0.5" "192.168.1.20" "true"  0 0 "192.168.1.20" "mDNS host change"
test_update_and_restart "10.0.0.5" "127.0.0.1" "true"  1 2 "127.0.0.1"    "restart failure preserves updated host"
test_update_and_restart "10.0.0.5" "10.0.0.5"  "true"  0 1 "10.0.0.5"     "same host is no-op"

echo ""
if [[ "$fail" -gt 0 ]]; then
    echo "FAILED: $fail tests failed, $pass passed"
    exit 1
fi
echo "All $pass tests passed!"
