#!/usr/bin/env bash
# shellcheck disable=SC2016
#
# Static + functional checks for three metadata-service.py hardening fixes:
#
# Bug 1 — defensive cache lock around OrderedDict mutations.
#   Today the only callers are enrich_artwork / enrich_tags via serial
#   `await loop.run_in_executor()` so there's no actual concurrency.
#   Adding a threading.Lock around _cache_set + _mark_failed prevents
#   future code (e.g. asyncio.gather) from corrupting the OrderedDict
#   internal doubly-linked list.
#
# Bug 3 — fuzzy match removed; "Sala" / "Sala Grande" no longer collide.
#   The previous \b-bounded fuzzy matched "Sala" inside "Sala Grande"
#   because the space is a word boundary. Worse failure mode than
#   refusing to resolve, since wrong room receives metadata/volume.
#   Now: exact match + `snapclient-` prefix strip only.
#
# Bug 3b — same exact-match rule applied to volume read/write paths.
#   _resolve_client_stream was hardened, but _find_client_volume and
#   set_client_volume kept `client_id in i or i in client_id` substring
#   matching — so volume routing could still hit the wrong room. Fix:
#   shared `_match_client_id` helper used by all three call sites.
#
# Bug 4 — MusicBrainz rate limiter releases lock before sleeping.
#   Old code held threading.Lock during time.sleep(1.1), serialising
#   the thread pool. Fix: reserve slot via timestamp under lock, sleep
#   outside.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SVC="$SCRIPT_DIR/../docker/metadata-service/metadata-service.py"

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

echo "=== Bug 1 — defensive cache lock ==="

assert 'grep -qE "^_cache_lock = threading\\.Lock\\(\\)" "$SVC"' \
       '_cache_lock module-level threading.Lock declared'

assert 'grep -A 10 "def _cache_set" "$SVC" | grep -qE "with _cache_lock:"' \
       '_cache_set acquires _cache_lock'

assert 'grep -A 10 "def _mark_failed" "$SVC" | grep -qE "with _cache_lock:"' \
       '_mark_failed acquires _cache_lock'

echo
echo "=== Bug 3 — fuzzy match removed ==="

# The new resolver must NOT use \b regex matching anymore.
resolve_block=$(grep -A 35 "def _resolve_client_stream" "$SVC")

assert '! echo "$resolve_block" | grep -qE "re\\.search"' \
       '_resolve_client_stream no longer uses re.search (fuzzy removed)'

assert 'echo "$resolve_block" | grep -qF "snapclient-"' \
       '_resolve_client_stream still supports the snapclient- prefix convention'

assert 'echo "$resolve_block" | grep -qF "client_id in self._client_stream_map"' \
       '_resolve_client_stream tries exact match first'

# The original belt-and-suspenders check banned `import re` outright
# under the rationale "no other place uses it". The status-page row
# parser (_structured_systemd_row) now legitimately uses pre-compiled
# patterns to tabularise systemd / container rows. The protected
# invariant remains: _resolve_client_stream itself must not use re.
# That's already covered by the re.search assertion above (line 66+).

# Functional: replicate the resolver and prove "Sala" no longer collides.
python3 - <<'PY'
import sys

def resolve(client_id, mapping):
    if client_id in mapping:
        return mapping[client_id]
    if client_id.startswith("snapclient-"):
        stripped = client_id[len("snapclient-"):]
        if stripped in mapping:
            return mapping[stripped]
    return None

cases = [
    # Multi-room setup with prefix-collision rooms
    ("Sala",       {"Sala Grande": "B"},                 None,     "Sala client must NOT match Sala Grande stream"),
    ("Sala Grande",{"Sala Grande": "B"},                 "B",      "Sala Grande exact match"),
    ("Sala",       {"Sala": "A", "Sala Grande": "B"},   "A",      "Sala matches its own stream when both exist"),
    # snapclient- prefix convention preserved
    ("snapclient-pi-server", {"pi-server": "S"},        "S",      "snapclient- prefix stripping still works"),
    # Cucina / Cucinino — previously the test case for #330
    ("Cucina",     {"Cucinino": "C"},                    None,     "Cucina no longer collides with Cucinino"),
    # No match
    ("Studio",     {"Sala": "A", "Camera": "B"},         None,     "no match returns None (not a wild guess)"),
]
fail = 0
for client, mapping, expected, desc in cases:
    got = resolve(client, mapping)
    if got == expected:
        print(f"  PASS: {desc}")
    else:
        print(f"  FAIL: {desc} (got {got!r}, expected {expected!r})")
        fail += 1
sys.exit(fail)
PY
rc=$?
if [[ "$rc" -eq 0 ]]; then
    pass=$((pass + 6))
else
    fail=$((fail + rc))
    pass=$((pass + 6 - rc))
fi

echo
echo "=== Bug 3b — volume routing uses exact match ==="

assert 'grep -qE "def _match_client_id\\(" "$SVC"' \
       '_match_client_id helper defined'

# All three call sites must use the helper. Substring matching anywhere
# below would let "Sala" hit "Sala Grande" on the volume path.
find_vol_block=$(grep -A 20 "def _find_client_volume" "$SVC")
set_vol_block=$(grep -A 30 "    def set_client_volume" "$SVC")

assert 'echo "$find_vol_block" | grep -qF "_match_client_id(client_id"' \
       '_find_client_volume uses _match_client_id helper'

assert 'echo "$set_vol_block" | grep -qF "_match_client_id(client_id"' \
       'set_client_volume uses _match_client_id helper'

assert '! echo "$find_vol_block" | grep -qE "client_id in i or i in client_id"' \
       '_find_client_volume no longer substring-matches'

assert '! echo "$set_vol_block" | grep -qE "client_id in i or i in client_id"' \
       'set_client_volume no longer substring-matches'

# Functional: replicate the helper and prove Sala / Sala Grande split correctly on the volume path.
python3 - <<'PY'
import sys

def match(client_id, identifiers):
    if any(client_id == i for i in identifiers if i):
        return True
    if client_id.startswith("snapclient-"):
        stripped = client_id[len("snapclient-"):]
        if any(stripped == i for i in identifiers if i):
            return True
    return False

cases = [
    # Volume read path: identifiers come from Snapcast client config (name + id).
    ("Sala",        ["Sala Grande", "snap-host-1"],         False, "Sala volume read must NOT hit Sala Grande client"),
    ("Sala Grande", ["Sala Grande", "snap-host-1"],         True,  "Sala Grande exact match"),
    ("Cucina",      ["Cucinino", "snap-host-2"],            False, "Cucina volume read must NOT hit Cucinino"),
    ("snapclient-pi-server", ["pi-server", "host-id"],      True,  "snapclient- prefix strip works for volume too"),
    ("Studio",      ["Sala", "Camera"],                     False, "no match returns False"),
    ("",            ["Sala"],                                False, "empty client_id never matches"),
]
fail = 0
for client, ids, expected, desc in cases:
    got = match(client, ids)
    if got == expected:
        print(f"  PASS: {desc}")
    else:
        print(f"  FAIL: {desc} (got {got!r}, expected {expected!r})")
        fail += 1
sys.exit(fail)
PY
rc=$?
if [[ "$rc" -eq 0 ]]; then
    pass=$((pass + 6))
else
    fail=$((fail + rc))
    pass=$((pass + 6 - rc))
fi

echo
echo "=== Bug 4 — MB rate limiter releases lock before sleep ==="

mb_block=$(grep -A 20 "^def _mb_rate_limit" "$SVC")

# The slot must be reserved under the lock by forward-dating the timestamp.
assert 'echo "$mb_block" | grep -qF "_mb_last_request = now + wait"' \
       'rate limiter forward-dates _mb_last_request to reserve slot'

# Sleep MUST be outside the lock block (after the `with _mb_lock:` closes).
sleep_lineno=$(grep -nE "^[[:space:]]*time\\.sleep\\(wait\\)" "$SVC" | head -1 | cut -d: -f1)
lock_close_lineno=$(awk '
    /^def _mb_rate_limit/ {in_func=1}
    in_func && /^[[:space:]]+with _mb_lock:/ {start=NR; in_block=1; next}
    in_func && in_block && /^[[:space:]]{0,4}[a-zA-Z]/ {print NR-1; exit}
' "$SVC")
if [[ -n "$sleep_lineno" && -n "$lock_close_lineno" && "$sleep_lineno" -gt "$lock_close_lineno" ]]; then
    echo "  PASS: time.sleep(wait) at line $sleep_lineno is AFTER lock closes at line $lock_close_lineno"
    pass=$((pass + 1))
else
    echo "  FAIL: sleep ordering wrong (sleep=$sleep_lineno, lock_close=$lock_close_lineno)"
    fail=$((fail + 1))
fi

echo
echo "=== Python syntax ==="
if python3 -m py_compile "$SVC"; then
    echo "  PASS: py_compile metadata-service.py"
    pass=$((pass + 1))
else
    echo "  FAIL: py_compile metadata-service.py"
    fail=$((fail + 1))
fi

echo
echo "=== Summary ==="
echo "  Pass: $pass"
echo "  Fail: $fail"

[[ "$fail" -eq 0 ]]
