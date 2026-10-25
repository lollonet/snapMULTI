#!/usr/bin/env bash
# Behavioural test for scripts/mpd-entrypoint.sh (container PID 1 of mpd):
#   - SIGTERM after MPD is up: the entrypoint forwards it and keeps waiting
#     until MPD has finished its own shutdown, then exits 0. Regression:
#     `wait $MPD_PID` returned 143 as soon as the trap ran and `set -e`
#     ended PID 1, so the kernel SIGKILLed MPD mid-shutdown (state/db lost).
#   - SIGTERM during the 120 s music wait exits promptly (trap set first).
#   - MUSIC_SOURCE=streaming-only skips the music wait.
#   - A real MPD failure exit code still propagates.
#
# mpd / mpc / nc / find are PATH stubs; the script runs under /bin/sh.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENTRYPOINT="$SCRIPT_DIR/../scripts/mpd-entrypoint.sh"

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

SBX="$(mktemp -d)"
EP_PID=""
cleanup() {
    [[ -n "$EP_PID" ]] && kill -KILL "$EP_PID" 2>/dev/null || true
    pkill -KILL -f "$SBX/bin/mpd" 2>/dev/null || true
    rm -rf "$SBX"
}
trap cleanup EXIT

mkdir -p "$SBX/bin"
# Fake MPD: graceful shutdown takes ~2 s (like flushing state + db).
cat > "$SBX/bin/mpd" <<'EOF'
#!/bin/sh
: > "$MARK_DIR/mpd.started"
if [ -n "${FAKE_MPD_EXIT:-}" ]; then sleep 1; exit "$FAKE_MPD_EXIT"; fi
trap 'sleep 2; : > "$MARK_DIR/mpd.shutdown"; exit 0' TERM
while :; do sleep 0.1; done
EOF
cat > "$SBX/bin/nc" <<'EOF'
#!/bin/sh
cat >/dev/null
echo "OK MPD 0.24.0"
EOF
cat > "$SBX/bin/mpc" <<'EOF'
#!/bin/sh
case "$*" in *stats*) echo "Songs:          5" ;; esac
EOF
# No music files ever (keeps the test independent of a host /music).
printf '#!/bin/sh\nexit 0\n' > "$SBX/bin/find"
chmod +x "$SBX/bin/"*

# Poll until "$1" is true or $2 tenths of a second elapse.
wait_for() {
    local cond="$1" tenths="$2" i
    for (( i = 0; i < tenths; i++ )); do
        eval "$cond" && return 0
        sleep 0.1
    done
    return 1
}

start_entrypoint() {
    rm -f "$SBX"/mpd.* "$SBX/out"
    MARK_DIR="$SBX" PATH="$SBX/bin:$PATH" sh "$ENTRYPOINT" > "$SBX/out" 2>&1 &
    EP_PID=$!
}

# Wait for the entrypoint to exit; sets rc to its exit status. Not run in
# $(...): a subshell cannot wait for the parent's child.
reap_entrypoint() {
    rc=0
    wait "$EP_PID" || rc=$?
    EP_PID=""
}

echo "## SIGTERM after MPD is up waits for MPD's own shutdown"
MUSIC_SOURCE=streaming-only start_entrypoint
wait_for "[[ -f '$SBX/mpd.started' ]] && grep -q 'auto_update handles' '$SBX/out'" 50 || true
assert "[[ -f '$SBX/mpd.started' ]]" "MPD started"
kill -TERM "$EP_PID"
reap_entrypoint
assert "[[ -f '$SBX/mpd.shutdown' ]]" "entrypoint exited only after MPD finished shutting down"
assert "[[ '$rc' == 0 ]]" "entrypoint exit status 0 on docker stop (got $rc)"
assert "! grep -q 'Waiting for music' '$SBX/out'" "MUSIC_SOURCE=streaming-only skips the music wait"

echo
echo "## SIGTERM during the music wait exits promptly"
MUSIC_SOURCE='' start_entrypoint
wait_for "grep -q 'Waiting for music' '$SBX/out'" 30 || true
assert "grep -q 'Waiting for music' '$SBX/out'" "music wait active when MUSIC_SOURCE is unset"
t0=$(date +%s%N)
kill -TERM "$EP_PID"
reap_entrypoint
elapsed_ms=$(( ($(date +%s%N) - t0) / 1000000 ))
assert "(( elapsed_ms < 2000 ))" "exited ${elapsed_ms} ms after SIGTERM (no 5 s sleep / 120 s wait)"
assert "[[ '$rc' == 0 ]]" "exit status 0 (got $rc)"
assert "[[ ! -f '$SBX/mpd.started' ]]" "MPD was never started"

echo
echo "## MPD failure exit code propagates"
MUSIC_SOURCE=streaming FAKE_MPD_EXIT=3 start_entrypoint
reap_entrypoint
assert "[[ '$rc' == 3 ]]" "non-signal MPD exit status propagates (got $rc)"

echo
echo "## Summary"
echo "  Passed: $pass"
echo "  Failed: $fail"
[[ $fail -eq 0 ]]
