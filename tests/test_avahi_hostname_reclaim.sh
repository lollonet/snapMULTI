#!/usr/bin/env bash
# Tests for reclaim_avahi_hostname (scripts/common/system-tune.sh): Avahi
# renamed to <host>-2 by a name conflict is asked over D-Bus to take the
# configured name back, without restarting the daemon. busctl / logger /
# sleep are stubs driven by files in a temp dir.
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

# busctl --system call <dest> / <iface> <Method> [sig value]
cat > "$STUBS/busctl" <<'EOF'
#!/bin/sh
[ -f "$STATE/off" ] && exit 1
echo "$6 $8" >> "$STATE/calls"
case "$6" in
    GetHostName) echo "s \"$(cat "$STATE/name")\"" ;;
    GetState)    echo "i $(cat "$STATE/state")" ;;
    SetHostName)
        if [ "$(cat "$STATE/on_set")" = "accept" ]; then
            echo "$8" > "$STATE/name"
        else
            echo "$8-2" > "$STATE/name"
        fi ;;
esac
EOF
printf '#!/bin/sh\necho "$*" >> "$STATE/log"\n' > "$STUBS/logger"
printf '#!/bin/sh\necho x >> "$STATE/sleeps"\n' > "$STUBS/sleep"
chmod +x "$STUBS"/*
PATH="$STUBS:$PATH"

reset_state() {
    # reset_state <current name> <accept|conflict> <server state>
    rm -rf "$STATE"
    mkdir -p "$STATE"
    echo "$1" > "$STATE/name"
    echo "$2" > "$STATE/on_set"
    echo "$3" > "$STATE/state"
    : > "$STATE/calls"
    : > "$STATE/log"
    : > "$STATE/sleeps"
}

run() {
    rc=0
    reclaim_avahi_hostname "$1" || rc=$?
}

set_calls() { grep -c '^SetHostName' "$STATE/calls" || true; }

echo "Name already correct"
reset_state snapvideo accept 2
run snapvideo
check "returns 0" test "$rc" -eq 0
check "no SetHostName" test "$(set_calls)" -eq 0
check "nothing logged" test ! -s "$STATE/log"

echo "Renamed to -2, re-claim succeeds"
reset_state snapvideo-2 accept 2
run snapvideo
check "returns 0" test "$rc" -eq 0
check "SetHostName called once with the configured name" \
    test "$(grep '^SetHostName' "$STATE/calls")" = "SetHostName snapvideo"
check "name is back" test "$(cat "$STATE/name")" = "snapvideo"
check "logs the re-claim" grep -q 're-claimed: snapvideo.local' "$STATE/log"
check "no daemon restart (busctl only)" test "$(grep -vcE '^(GetHostName|GetState|SetHostName)' "$STATE/calls" || true)" -eq 0

echo "Conflict persists"
reset_state snapvideo-2 conflict 2
run snapvideo
check "returns 1" test "$rc" -eq 1
check "logs a warning naming the stuck name" \
    grep -q 'warning Avahi host name still snapvideo-2.local' "$STATE/log"

echo "Avahi not on D-Bus"
reset_state snapvideo-2 accept 2
touch "$STATE/off"
run snapvideo
check "returns 0" test "$rc" -eq 0
check "nothing logged" test ! -s "$STATE/log"

echo "Server never reaches RUNNING"
reset_state snapvideo-2 accept 1
run snapvideo
check "wait is bounded to 10 polls" test "$(grep -c x "$STATE/sleeps")" -eq 10
check "still checks the name afterwards" test "$rc" -eq 0

echo "Installer wiring"
check "install_boot_tune_service writes the timer" \
    grep -q 'cat > /etc/systemd/system/snapmulti-avahi-name.timer' "$SYSTEM_TUNE"
check "install_boot_tune_service enables the timer" \
    grep -q 'systemctl enable snapmulti-avahi-name.timer' "$SYSTEM_TUNE"
check "generated script calls reclaim_avahi_hostname" \
    awk '/cat > \/usr\/local\/bin\/snapmulti-avahi-name.sh/{f=1} f && /reclaim_avahi_hostname/{ok=1; exit} f && /^NEOF$/{exit} END{exit !ok}' "$SYSTEM_TUNE"

echo ""
echo "Results: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
