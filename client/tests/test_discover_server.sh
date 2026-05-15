#!/usr/bin/env bash
# Functional checks for discover-server.sh's _apply_server: write-before-restart ordering, no-op short-circuit, restart-failure preserves new .env.

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

# Extract production functions. We need three:
#   _current_host  — reads SNAPSERVER_HOST from $ENV_FILE
#   _apply_server  — the actual subject under test
# `_log` and `_compose_up` are stubbed below so the test stays
# hermetic (no docker calls, no journald).
eval "$(sed -n '/^_current_host()/,/^}/p' "$DISCOVER_SH")"
eval "$(sed -n '/^_apply_server()/,/^}/p' "$DISCOVER_SH")"

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

# Stubs replacing _log (production: writes to journal) and _compose_up
# (production: cd /opt/snapclient && docker compose up -d). The stub for
# _compose_up records its "restart" event to $COMPOSE_LOG and returns
# the rc the test wants — that's how we simulate failure case below.
COMPOSE_LOG=""
COMPOSE_RC=0
_log() { :; }
_compose_up() {
    # Snapshot .env at restart time so the assertion can prove ordering (flush-then-restart, not the other way).
    if [[ -n "$COMPOSE_LOG" ]]; then
        grep '^SNAPSERVER_HOST=' "$ENV_FILE" | cut -d= -f2- > "$COMPOSE_LOG"
    fi
    return "$COMPOSE_RC"
}

echo "Testing discover-server _apply_server + restart ordering..."

test_apply() {
    local initial="$1" new_host="$2" watch_mode="$3" sim_compose_rc="$4" \
          expected_rc="$5" expected_host="$6" desc="$7"
    local tmpdir
    tmpdir=$(mktemp -d)

    # shellcheck disable=SC2034  # module-level vars used by eval'd functions
    ENV_FILE="$tmpdir/.env"
    # shellcheck disable=SC2034
    LAST_IP_FILE="$tmpdir/last-ip"
    COMPOSE_LOG="$tmpdir/restart.log"
    COMPOSE_RC="$sim_compose_rc"
    # shellcheck disable=SC2034  # consumed by _apply_server
    WATCH_MODE="$watch_mode"

    printf 'SNAPSERVER_HOST=%s\n' "$initial" > "$ENV_FILE"

    local rc=0
    _apply_server "$new_host" || rc=$?

    local current restarted_with
    current=$(grep '^SNAPSERVER_HOST=' "$ENV_FILE" | cut -d= -f2-)
    restarted_with="$(cat "$COMPOSE_LOG" 2>/dev/null || echo '')"

    assert_eq "$rc" "$expected_rc" "$desc: return code"
    assert_eq "$current" "$expected_host" "$desc: .env final value"
    if [[ "$watch_mode" == "true" && "$initial" != "$new_host" ]]; then
        # _compose_up should have been invoked AFTER .env was flushed —
        # so $restarted_with equals the new host, not the old one.
        assert_eq "$restarted_with" "$expected_host" \
            "$desc: restart sees new host (ordering: .env flushed before compose up)"
    fi
    # Non-watch / no-change paths must NEVER invoke compose — $COMPOSE_LOG
    # stays empty. Without this assertion a regression that accidentally
    # called compose in non-watch mode (or on a same-host no-op) would
    # silently pass the existing rc / .env checks.
    if [[ "$watch_mode" == "false" || "$initial" == "$new_host" ]]; then
        assert_eq "$restarted_with" "" \
            "$desc: compose NOT invoked (no-op or non-watch mode)"
    fi

    rm -rf "$tmpdir"
}

# Both-mode swap: discover-server picks 127.0.0.1, watch_mode invokes restart.
test_apply "10.0.0.5" "127.0.0.1" "true"  0 0 "127.0.0.1"    "both-mode change"

# mDNS host change: classic failover scenario.
test_apply "10.0.0.5" "192.168.1.20" "true"  0 0 "192.168.1.20" "mDNS host change"

# Restart failure: _compose_up returns non-zero, but .env stays at the new
# value. _apply_server itself returns 0 (the change WAS applied to .env);
# operator/caller can detect the compose failure via journald.
test_apply "10.0.0.5" "127.0.0.1" "true"  1 0 "127.0.0.1" \
    "restart failure preserves updated .env"

# Same-host no-op: _apply_server returns 1, .env unchanged, no compose call.
test_apply "10.0.0.5" "10.0.0.5" "true"  0 1 "10.0.0.5" "same host is no-op"

# Non-watch mode: still write .env but skip the compose restart. Some
# callers (one-shot discovery, dry-runs) rely on this path.
test_apply "10.0.0.5" "192.168.1.20" "false" 0 0 "192.168.1.20" \
    "non-watch mode writes .env but does not restart"

echo ""
if [[ "$fail" -gt 0 ]]; then
    echo "FAILED: $fail tests failed, $pass passed"
    exit 1
fi
echo "All $pass tests passed!"
