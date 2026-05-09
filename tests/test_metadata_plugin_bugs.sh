#!/usr/bin/env bash
# shellcheck disable=SC2016  # assert() conditions are eval'd, single quotes intentional.
#
# Static checks for three latent metadata-plugin bugs surfaced in code review:
#
#   1. meta_shairport.py + meta_tidal.py: non-blocking stdin.read() can return
#      None on would-block (partial UTF-8 buffer). The old code matched both
#      None and "" via `if not chunk:`, prematurely closing stdin and silently
#      dropping snapserver commands.
#
#   2. meta_shairport.py: when the metadata pipe contains an orphan </item>
#      BEFORE the next <item> (corrupt pipe / mid-stream startup), the old
#      `else: break` left the orphan in pipe_buffer forever. The buffer grew
#      to MAX_PIPE_BUFFER (10 MB) before reset, losing all metadata in
#      between.
#
#   3. metadata-service.py: ws_handler mutated the global ws_clients set
#      without holding ws_clients_lock, while _broadcast_server_info iterated
#      it under the lock. set.add() is atomic but iteration during mutation
#      can raise "Set changed size during iteration". All mutations now
#      acquire the lock.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SHAIRPORT="$SCRIPT_DIR/../scripts/meta_shairport.py"
TIDAL="$SCRIPT_DIR/../scripts/meta_tidal.py"
METADATA="$SCRIPT_DIR/../docker/metadata-service/metadata-service.py"

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

echo "=== Bug #1 — non-blocking stdin.read() None vs EOF distinction ==="

assert 'grep -qE "if chunk is None:" "$SHAIRPORT"' \
       'meta_shairport.py distinguishes chunk is None (would-block) from "" (EOF)'

assert 'grep -qE "if chunk is None:" "$TIDAL"' \
       'meta_tidal.py distinguishes chunk is None (would-block) from "" (EOF)'

# Defensive: the old anti-pattern (closing stdin on `if not chunk:` without
# the None check above) must not return.
shairport_close=$(grep -nE "sys\\.stdin\\.close\\(\\)" "$SHAIRPORT" | head -1 | cut -d: -f1)
shairport_none=$(grep -nE "if chunk is None:" "$SHAIRPORT" | head -1 | cut -d: -f1)
if [[ -n "$shairport_close" && -n "$shairport_none" && "$shairport_none" -lt "$shairport_close" ]]; then
    echo "  PASS: meta_shairport.py None-check (line $shairport_none) precedes stdin.close (line $shairport_close)"
    pass=$((pass + 1))
else
    echo "  FAIL: meta_shairport.py None-check ordering wrong (none=$shairport_none, close=$shairport_close)"
    fail=$((fail + 1))
fi

echo
echo "=== Bug #2 — meta_shairport.py orphan </item> handling ==="

# The fix replaces `else: break` (which left the buffer untouched) with
# `pipe_buffer = pipe_buffer[start:]` so the next iteration starts fresh
# at the next <item>. Static check: the new pattern is present.
assert 'awk "/while b.<item>. in pipe_buffer/,/^[[:space:]]*pipe_buffer = b/" "$SHAIRPORT" | grep -qE "pipe_buffer = pipe_buffer\\[start:\\]"' \
       'orphan </item> branch slices buffer to next <item> instead of leaving it stuck'

echo
echo "=== Bug #4 — ws_clients lock invariant ==="

# Three mutation paths must each acquire ws_clients_lock:
# subscribe, subscribe_stream (covered by subscribe block test below),
# and disconnect (finally). Plus the broadcast paths (_broadcast_to_stream
# and the stream_switched_clients loop) collect failures and
# difference_update under the lock.

# Specifically the subscribe path must wrap discard+add together.
subscribe_block=$(awk '/if .subscribe. in data:/,/continue$/' "$METADATA" | head -25)
assert 'echo "$subscribe_block" | grep -qE "async with ws_clients_lock:"' \
       'subscribe path is wrapped in ws_clients_lock'

# The disconnect path (finally block) must also acquire the lock.
finally_block=$(awk '/finally:/,/logger.info.*disconnected/' "$METADATA")
assert 'echo "$finally_block" | grep -qE "async with ws_clients_lock:"' \
       'disconnect path acquires ws_clients_lock around discard'

# The two collect-then-flush broadcast paths in the poll loop now mutate
# ws_clients via difference_update under the lock (instead of bare
# .discard inside the iteration).
assert 'grep -qE "ws_clients\\.difference_update\\(clients_to_remove\\)" "$METADATA"' \
       '_broadcast_to_stream uses difference_update for failed sends'

assert 'grep -qE "ws_clients\\.difference_update\\(stream_switch_failures\\)" "$METADATA"' \
       'stream-switch broadcast uses difference_update for failed sends'

echo
echo "=== Python syntax ==="
for f in "$SHAIRPORT" "$TIDAL" "$METADATA"; do
    if python3 -m py_compile "$f" 2>/dev/null; then
        echo "  PASS: py_compile $(basename "$f")"
        pass=$((pass + 1))
    else
        echo "  FAIL: py_compile $(basename "$f")"
        fail=$((fail + 1))
    fi
done

echo
echo "=== Summary ==="
echo "  Pass: $pass"
echo "  Fail: $fail"

[[ "$fail" -eq 0 ]]
