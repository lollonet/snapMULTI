#!/usr/bin/env bash
# shellcheck disable=SC2016  # eval'd assertion bodies use single quotes.
#
# Static checks for the fb-display + audio-visualizer shutdown fix.
#
# The bug: on `docker stop` (issued by snapclient.service ExecStop=docker
# compose down at reboot), the python3 main process inside fb-display /
# audio-visualizer ignored SIGTERM. Plain `signal.signal(SIGTERM, cleanup)`
# does not deliver under `asyncio.run(main())` because the asyncio event
# loop spends its time inside `await` points where Python signal handlers
# never fire. Docker waited stop_grace_period (default 10 s) then SIGKILL,
# but the host-visible PID lingered as a zombie until systemd-shutdown's
# DefaultTimeoutStopSec (~90 s). User saw `Waiting for process: NNNN
# (python3)` for ~3 minutes per reboot.
#
# Two coordinated fixes:
#   1. docker-compose.yml gives both services `init: true` (tini as PID 1
#      to propagate signals + reap zombies) and `stop_grace_period: 2s`
#      (Docker SIGKILLs quickly so the host-side PID disappears).
#   2. fb_display.py + visualizer.py register signal handlers via
#      `loop.add_signal_handler()` instead of `signal.signal()` so SIGTERM
#      is processed by the asyncio loop directly.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE="$SCRIPT_DIR/../client/common/docker-compose.yml"
SERVER_COMPOSE="$SCRIPT_DIR/../docker-compose.yml"
FB_PY="$SCRIPT_DIR/../client/common/docker/fb-display/fb_display.py"
VIZ_PY="$SCRIPT_DIR/../client/common/docker/audio-visualizer/visualizer.py"
META_PY="$SCRIPT_DIR/../docker/metadata-service/metadata-service.py"

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

echo "=== docker-compose.yml — init + stop_grace_period ==="

# Extract each service's block (from `^  fb-display:` to next `^  [a-z]` or EOF).
fb_block=$(awk '
    /^  fb-display:/ {in_block=1; print; next}
    in_block && /^  [a-z]/ {exit}
    in_block {print}
' "$COMPOSE")
viz_block=$(awk '
    /^  audio-visualizer:/ {in_block=1; print; next}
    in_block && /^  [a-z]/ {exit}
    in_block {print}
' "$COMPOSE")

assert 'echo "$fb_block" | grep -qE "^[[:space:]]+init: true"' \
       'fb-display sets init: true'
assert 'echo "$fb_block" | grep -qE "^[[:space:]]+stop_grace_period: 2s"' \
       'fb-display sets stop_grace_period: 2s'

assert 'echo "$viz_block" | grep -qE "^[[:space:]]+init: true"' \
       'audio-visualizer sets init: true'
assert 'echo "$viz_block" | grep -qE "^[[:space:]]+stop_grace_period: 2s"' \
       'audio-visualizer sets stop_grace_period: 2s'

echo
echo "=== fb_display.py — asyncio-aware signal handler ==="

assert 'grep -qE "loop\.add_signal_handler\(.*cleanup" "$FB_PY"' \
       'fb_display.py uses loop.add_signal_handler(...) for SIGTERM'

# The legacy signal.signal() registration must be GONE from __main__.
main_block=$(awk '/^if __name__ == "__main__":/{p=1} p' "$FB_PY")
assert '! echo "$main_block" | grep -qE "signal\.signal\(signal\.SIGTERM"' \
       'fb_display.py __main__ no longer calls signal.signal(SIGTERM, ...)'

assert 'grep -qE "asyncio\.run\(_async_main\(\)\)" "$FB_PY"' \
       'fb_display.py __main__ runs the async wrapper'

echo
echo "=== visualizer.py — asyncio-aware signal handler ==="

assert 'grep -qE "loop\.add_signal_handler\(.*cleanup" "$VIZ_PY"' \
       'visualizer.py uses loop.add_signal_handler(...) for SIGTERM'

main_block=$(awk '/^if __name__ == "__main__":/{p=1} p' "$VIZ_PY")
assert '! echo "$main_block" | grep -qE "signal\.signal\(signal\.SIGTERM"' \
       'visualizer.py __main__ no longer calls signal.signal(SIGTERM, ...)'

assert 'grep -qE "asyncio\.run\(_async_main\(\)\)" "$VIZ_PY"' \
       'visualizer.py __main__ runs the async wrapper'

echo
echo "=== server docker-compose.yml — init + stop_grace_period for metadata ==="

meta_block=$(awk '
    /^  metadata:/ {in_block=1; print; next}
    in_block && /^  [a-z]/ {exit}
    in_block {print}
' "$SERVER_COMPOSE")

assert 'echo "$meta_block" | grep -qE "^[[:space:]]+init: true"' \
       'metadata sets init: true'
assert 'echo "$meta_block" | grep -qE "^[[:space:]]+stop_grace_period: 2s"' \
       'metadata sets stop_grace_period: 2s'

echo
echo "=== metadata-service.py — asyncio-aware signal handler ==="

assert 'grep -qE "loop\.add_signal_handler" "$META_PY"' \
       'metadata-service.py uses loop.add_signal_handler(...)'

assert 'grep -qE "asyncio\.run\(_async_main\(\)\)" "$META_PY"' \
       'metadata-service.py runs the async wrapper'

echo
echo "=== Python syntax ==="
for f in "$FB_PY" "$VIZ_PY" "$META_PY"; do
    # py_compile: safe path handling (no quoting hazards) and matches
    # how Python itself validates the source on import.
    if python3 -m py_compile "$f" 2>/dev/null; then
        echo "  PASS: python3 -m py_compile $(basename "$f")"
        pass=$((pass + 1))
    else
        echo "  FAIL: python3 -m py_compile $(basename "$f")"
        fail=$((fail + 1))
    fi
done

echo
echo "=== Summary ==="
echo "  Pass: $pass"
echo "  Fail: $fail"

[[ "$fail" -eq 0 ]]
