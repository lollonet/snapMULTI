#!/usr/bin/env bash
# Tests for reclaim_avahi_hostname (scripts/common/system-tune.sh): Avahi
# renamed to <host>-2 by a name conflict is asked over D-Bus to take the
# configured name back, without restarting the daemon. busctl / systemctl /
# logger / sleep / hostname are stubs driven by files in a temp dir.
# Bash 3.2 + bash 5 compatible.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SYSTEM_TUNE="$SCRIPT_DIR/../scripts/common/system-tune.sh"

# shellcheck source=../scripts/common/system-tune.sh
source "$SYSTEM_TUNE"

pass=0
fail=0

check() {
    local desc="$1"
    shift
    if "$@"; then
        echo "  PASS: $desc"
        pass=$((pass + 1))
    else
        echo "  FAIL: $desc"
        fail=$((fail + 1))
    fi
}

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
STUBS="$TMP/stubs"
mkdir -p "$STUBS"
export STATE="$TMP/state"
export AVAHI_DAEMON_CONF="$STATE/avahi-daemon.conf"
export AVAHI_RECLAIM_STATE="$STATE/attempts"

# busctl --system call <dest> / <iface> <Method> [sig value]
cat > "$STUBS/busctl" <<'EOF'
#!/bin/sh
[ -f "$STATE/off" ] && exit 1
echo "$6 $8" >> "$STATE/calls"
case "$6" in
    GetHostName) echo "s \"$(cat "$STATE/name")\"" ;;
    GetState)    echo "i $(cat "$STATE/state")" ;;
    SetHostName)
        case "$(cat "$STATE/on_set")" in
            accept)   echo "$8" > "$STATE/name" ;;
            conflict) echo "$8-2" > "$STATE/name" ;;
            reject)   echo "Call failed: Access denied" >&2; exit 1 ;;
        esac ;;
esac
EOF
printf '#!/bin/sh\necho "systemctl $*" >> "$STATE/calls"\n' > "$STUBS/systemctl"
printf '#!/bin/sh\necho "$*" >> "$STATE/log"\n' > "$STUBS/logger"
printf '#!/bin/sh\necho x >> "$STATE/sleeps"\n' > "$STUBS/sleep"
printf '#!/bin/sh\ncat "$STATE/hostname"\n' > "$STUBS/hostname"
chmod +x "$STUBS"/*
PATH="$STUBS:$PATH"

reset_state() {
    # reset_state <avahi name> <accept|conflict|reject> <server state>
    rm -rf "$STATE"
    mkdir -p "$STATE"
    echo "$1" > "$STATE/name"
    echo "$2" > "$STATE/on_set"
    echo "$3" > "$STATE/state"
    echo "snapvideo" > "$STATE/hostname"
    printf '[server]\nhost-name=snapvideo\n' > "$AVAHI_DAEMON_CONF"
    : > "$STATE/calls"
    : > "$STATE/log"
    : > "$STATE/sleeps"
}

run() {
    rc=0
    reclaim_avahi_hostname || rc=$?
}

set_calls() { grep -c '^SetHostName' "$STATE/calls" || true; }

echo "Name already correct"
reset_state snapvideo accept 2
run
check "returns 0" test "$rc" -eq 0
check "no SetHostName" test "$(set_calls)" -eq 0
check "nothing logged" test ! -s "$STATE/log"

echo "Comparison ignores case"
reset_state SnapVideo accept 2
run
check "no SetHostName for a case-only difference" test "$(set_calls)" -eq 0

echo "Renamed to -2, re-claim succeeds"
reset_state snapvideo-2 accept 2
run
check "returns 0" test "$rc" -eq 0
check "SetHostName called once with the configured name" \
    test "$(grep '^SetHostName' "$STATE/calls")" = "SetHostName snapvideo"
check "name is back" test "$(cat "$STATE/name")" = "snapvideo"
check "logs the re-claim" grep -q 're-claimed: snapvideo.local' "$STATE/log"
check "no systemctl call (no daemon or container restart)" \
    test "$(grep -c '^systemctl' "$STATE/calls" || true)" -eq 0
check "attempt counter cleared after success" test ! -e "$AVAHI_RECLAIM_STATE"

echo "Wanted name comes from avahi-daemon.conf, domain dropped"
reset_state snapvideo-2 accept 2
printf '[server]\nhost-name=livingroom.lan\n' > "$AVAHI_DAEMON_CONF"
run
check "SetHostName uses host-name= without the domain" \
    test "$(grep '^SetHostName' "$STATE/calls")" = "SetHostName livingroom"

echo "No host-name= line: falls back to the hostname"
reset_state snapvideo-2 accept 2
printf '[server]\n' > "$AVAHI_DAEMON_CONF"
echo "kitchen.home" > "$STATE/hostname"
run
check "SetHostName uses the short hostname" \
    test "$(grep '^SetHostName' "$STATE/calls")" = "SetHostName kitchen"

echo "Conflict persists"
reset_state snapvideo-2 conflict 2
run
check "returns 1" test "$rc" -eq 1
check "logs a warning naming the stuck name" \
    grep -q 'warning Avahi host name still snapvideo-2.local' "$STATE/log"

echo "Retry budget: at most $AVAHI_RECLAIM_MAX_ATTEMPTS attempts per boot"
reset_state snapvideo-2 conflict 2
for _ in 1 2 3 4 5 6; do run; done
check "SetHostName called $AVAHI_RECLAIM_MAX_ATTEMPTS times" \
    test "$(set_calls)" -eq "$AVAHI_RECLAIM_MAX_ATTEMPTS"
check "logs that it gave up" grep -q 'gave up after 4 attempts' "$STATE/log"
check "returns 0 once the budget is spent" test "$rc" -eq 0

echo "SetHostName rejected"
reset_state snapvideo-2 reject 2
run
check "returns 1" test "$rc" -eq 1
check "logs the D-Bus error, not a LAN conflict" \
    grep -q 'SetHostName snapvideo rejected: Call failed: Access denied' "$STATE/log"
check "no 'stale cache' warning" sh -c "! grep -q 'stale cache' '$STATE/log'"

echo "Avahi not on D-Bus"
reset_state snapvideo-2 accept 2
touch "$STATE/off"
run
check "returns 0" test "$rc" -eq 0
check "nothing logged" test ! -s "$STATE/log"
check "safe under set -euo pipefail without || guard" \
    "$BASH" -c "set -euo pipefail; PATH='$PATH'; source '$SYSTEM_TUNE'; reclaim_avahi_hostname; echo ok" \
    >/dev/null 2>&1

echo "Server never reaches RUNNING"
reset_state snapvideo-2 accept 1
run
check "wait is bounded to 10 polls" test "$(grep -c x "$STATE/sleeps")" -eq 10
check "still checks the name afterwards" test "$rc" -eq 0

echo "Installer wiring"
check "install_boot_tune_service writes the timer" \
    grep -q 'cat > /etc/systemd/system/snapmulti-avahi-name.timer' "$SYSTEM_TUNE"
check "install_boot_tune_service enables the timer" \
    grep -q 'systemctl enable snapmulti-avahi-name.timer' "$SYSTEM_TUNE"
gen=$(awk '/cat > \/usr\/local\/bin\/snapmulti-avahi-name.sh/{f=1; next} f && /^NEOF$/{exit} f' "$SYSTEM_TUNE")
check "generated script calls reclaim_avahi_hostname" grep -q 'reclaim_avahi_hostname || true' <<< "$gen"
check "generated script always exits 0" sh -c "! grep -qE 'exit [1-9]|exit \\\$' <<'EOF'
$gen
EOF"
check "generated script logs a source failure" grep -q 'cannot source' <<< "$gen"

echo ""
echo "Results: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
