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

# Production targets Linux (GNU sed, `sed -i EXPR FILE`). BSD/macOS sed
# needs an explicit empty backup suffix (`sed -i '' EXPR FILE`), so only
# there wrap sed to inject it. GNU sed would read '' as the expression.
MOCK_BIN=$(mktemp -d)
trap 'rm -rf "$MOCK_BIN"' EXIT
REAL_SED=$(command -v sed)
if ! "$REAL_SED" --version >/dev/null 2>&1; then
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
fi
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

# ── Watch mode: _reconcile_container_env must not undo a deliberate stop ──
eval "$(sed -n '/^_snapclient_unit_stopped()/,/^}/p' "$DISCOVER_SH")"
eval "$(sed -n '/^_reconcile_container_env()/,/^}/p' "$DISCOVER_SH")"

# docker stub: `inspect --format '{{.State...}}'` → $FAKE_STATE ("" = no
# container); env inspect → SNAPSERVER_HOST=$FAKE_CONTAINER_HOST.
FAKE_STATE=""
FAKE_CONTAINER_HOST=""
docker() {
    if [[ "$*" == *".State.Status"* ]]; then
        [[ -n "$FAKE_STATE" ]] && echo "$FAKE_STATE"
        [[ -n "$FAKE_STATE" ]]
        return
    fi
    if [[ "$*" == *".Config.Env"* ]]; then
        echo "SNAPSERVER_HOST=$FAKE_CONTAINER_HOST"
        return 0
    fi
    return 1
}
# systemctl stub: FAKE_UNIT = installed state, FAKE_ACTIVE = is-active output.
FAKE_UNIT=installed
FAKE_ACTIVE=active
systemctl() {
    case "$1" in
        cat) [[ "$FAKE_UNIT" == "installed" ]] ;;
        is-active) echo "$FAKE_ACTIVE"; [[ "$FAKE_ACTIVE" == "active" ]] ;;
        *) return 0 ;;
    esac
}

test_reconcile() {
    local state="$1" unit="$2" active="$3" expect_up="$4" expect_rc="$5" desc="$6"
    local tmpdir rc=0
    tmpdir=$(mktemp -d)
    # shellcheck disable=SC2034  # read by eval'd _current_host
    ENV_FILE="$tmpdir/.env"
    printf 'SNAPSERVER_HOST=10.0.0.5\n' > "$ENV_FILE"
    COMPOSE_LOG="$tmpdir/restart.log"
    COMPOSE_RC=0
    FAKE_STATE="$state"
    FAKE_CONTAINER_HOST="10.0.0.5"
    FAKE_UNIT="$unit"
    FAKE_ACTIVE="$active"
    _reconcile_container_env || rc=$?
    local invoked=no
    [[ -f "$COMPOSE_LOG" ]] && invoked=yes
    assert_eq "$invoked" "$expect_up" "$desc: compose up invoked"
    assert_eq "$rc" "$expect_rc" "$desc: return code"
    rm -rf "$tmpdir"
}

echo ""
echo "Testing discover-server _reconcile_container_env (watch mode)..."
test_reconcile "exited 0 false"   installed inactive no  1 "systemctl stop snapclient (unit inactive)"
test_reconcile "exited 0 false"   installed active   no  1 "docker compose stop (clean exit 0)"
test_reconcile "exited 143 false" installed active   no  1 "docker stop SIGTERM exit 143"
test_reconcile "exited 137 false" installed active   no  1 "docker stop timeout SIGKILL exit 137"
test_reconcile "exited 137 true"  installed active   yes 1 "OOM-killed container is restarted"
test_reconcile "exited 1 false"   installed active   yes 1 "abnormal exit is restarted"
test_reconcile "created 0 false"  installed active   yes 1 "created-but-never-started is restarted"
test_reconcile "created 0 false"  installed failed   yes 1 "failed unit is not treated as a stop"
test_reconcile "created 0 false"  missing   inactive yes 1 "no systemd unit installed: state decides"
test_reconcile "restarting 1 false" installed active no  1 "restarting is left to docker"
test_reconcile "running 0 false"  installed active   no  0 "running, no drift: no-op"
test_reconcile ""                 installed active   no  0 "no container: caller discovers"

# ── Boot mode: _choose_boot_server keeps a healthy current server ──
eval "$(sed -n '/^_pick_failover_ipv4()/,/^}/p' "$DISCOVER_SH")"
eval "$(sed -n '/^_choose_boot_server()/,/^}/p' "$DISCOVER_SH")"
# shellcheck disable=SC2034  # read by eval'd _choose_boot_server
SNAPSERVER_PORT=1704
FAKE_ALIVE=""          # space-separated IPs that answer TCP
FAKE_MDNS=""           # newline-separated advertised IPs
DISCOVER_CALLS=0
_tcp_alive() { [[ " $FAKE_ALIVE " == *" $1 "* ]]; }
_discover_all_ipv4() {
    DISCOVER_CALLS=$((DISCOVER_CALLS + 1))
    echo "$DISCOVER_CALLS" > "$DISCOVER_COUNT_FILE"
    [[ -n "$FAKE_MDNS" ]] && printf '%s\n' "$FAKE_MDNS"
    return 0
}
DISCOVER_COUNT_FILE=$(mktemp)

test_boot() {
    local current="$1" alive="$2" mdns="$3" expected="$4" desc="$5" got
    FAKE_ALIVE="$alive"
    FAKE_MDNS="$mdns"
    echo 0 > "$DISCOVER_COUNT_FILE"
    got=$(_choose_boot_server "$current" 2>/dev/null || true)
    assert_eq "$got" "$expected" "$desc"
}

echo ""
echo "Testing discover-server _choose_boot_server (boot mode)..."
two=$'192.168.1.10\n192.168.1.20'
test_boot "192.168.1.20" "192.168.1.10 192.168.1.20" "$two" "192.168.1.20" \
    "two servers, current alive → keep current (no hop on reboot)"
test_boot "192.168.1.20" "" "$two" "192.168.1.20" \
    "current not answering yet but still advertised → keep current"
test_boot "192.168.1.30" "192.168.1.10" "$two" "192.168.1.10" \
    "current gone (not alive, not advertised) → failover"
test_boot "" "" "$two" "192.168.1.10" \
    "fresh install (no current) → first discovered"
test_boot "192.168.1.30" "" "" "" \
    "nothing discovered, current dead → no choice"
FAKE_ALIVE=""; FAKE_MDNS="$two"; echo 0 > "$DISCOVER_COUNT_FILE"
_choose_boot_server "192.168.1.30" >/dev/null 2>&1 || true
assert_eq "$(cat "$DISCOVER_COUNT_FILE")" "1" "failover path reuses the single mDNS scan"
rm -f "$DISCOVER_COUNT_FILE"

echo ""
if [[ "$fail" -gt 0 ]]; then
    echo "FAILED: $fail tests failed, $pass passed"
    exit 1
fi
echo "All $pass tests passed!"
