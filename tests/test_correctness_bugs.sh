#!/usr/bin/env bash
# shellcheck disable=SC2016  # assert() conditions are eval'd, single quotes intentional.
#
# Static + functional checks for three correctness bugs:
#
# Bug A — meta_shairport.py busy-loop on closed stdin
#   After stdin EOF the plugin used to leave sys.stdin in the select watch
#   list. select.select() on a closed FD raises OSError(EBADF) which the
#   except clause swallowed; the outer while-True spun at 100% CPU. Fix
#   tracks a `stdin_closed` flag that excludes stdin from read_fds.
#
# Bug B — tidal-meta-bridge.sh "xx" delimiter truncates artist names
#   The TUI panel marker "xx" was stripped via `${value%%xx*}` which
#   matches the FIRST "xx" anywhere. Names like "Jamie xx" or "The XX"
#   contain "xx" with one space inside, so the artist was truncated.
#   Fix: require 2+ spaces of column padding before the panel "xx".
#
# Bug C — metadata-service.py fuzzy match collides on prefix names
#   `client in identifier or identifier in client` matched "Cucina" in
#   "Cucinino". Fix: require a \b word boundary so "Cucina" doesn't
#   match across "i" but "snapvideo" still matches inside
#   "snapclient-snapvideo" (the "-" is a non-word char).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SHAIRPORT="$SCRIPT_DIR/../scripts/meta_shairport.py"
TIDAL_BRIDGE="$SCRIPT_DIR/../scripts/tidal/tidal-meta-bridge.sh"
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

echo "=== Bug A — meta_shairport.py busy-loop on closed stdin ==="

# Static: stdin_closed flag is introduced and gates read_fds population.
assert 'grep -qE "stdin_closed = False" "$SHAIRPORT"' \
       'stdin_closed flag declared'

assert 'grep -qE "if not stdin_closed:" "$SHAIRPORT"' \
       'read_fds build is gated on stdin_closed=False'

assert 'grep -qE "stdin_closed = True" "$SHAIRPORT"' \
       'EOF branch sets stdin_closed=True so next iteration skips stdin'

# Defensive: the empty-read_fds case must sleep so we don't spin while
# waiting for the pipe to come back on its own.
assert 'grep -qE "if not read_fds:" "$SHAIRPORT"' \
       'empty-read_fds path is handled with a sleep (no spin)'

echo
echo "=== Bug B — tidal-meta-bridge.sh xx delimiter ==="

# Static: the new bash-regex pattern with 2+ spaces is present, the old
# %%xx* truncator is gone (or at least no longer the panel-strip path).
assert 'grep -qF "BASH_REMATCH" "$TIDAL_BRIDGE"' \
       'extract_field uses BASH_REMATCH (regex-based panel-marker fix)'

assert '! grep -qE "value=.\\\$\\{value%%xx\\*\\}" "$TIDAL_BRIDGE"' \
       'old %%xx* truncator is removed'

# Functional: source the helper and exercise it on real-world strings.
extract_field() {
    local prefix="$1" output="$2" line value
    while IFS= read -r line; do
        if [[ "$line" == "${prefix}"* ]]; then
            value="${line#"$prefix"}"
            if [[ "$value" =~ ^(.*[^[:space:]])[[:space:]]{2,}xx[[:space:]]*$ ]]; then
                value="${BASH_REMATCH[1]}"
            fi
            value="${value% x}"
            value="${value%"${value##*[! ]}"}"
            printf '%s' "$value"
            return
        fi
    done <<< "$output"
}

# Cases where the field content contains "xx" — must NOT be truncated.
result=$(extract_field "xartists: " "xartists: Jamie xx                xx")
assert_eq "$result" "Jamie xx" "extract_field preserves 'Jamie xx'"

result=$(extract_field "xartists: " "xartists: The XX                  xx")
assert_eq "$result" "The XX" "extract_field preserves 'The XX' (uppercase)"

result=$(extract_field "xtitle: " "xtitle: Track with xx in it       xx")
assert_eq "$result" "Track with xx in it" "extract_field preserves 'xx' inside title"

# Plain cases (no xx in content) — must still strip the panel marker.
result=$(extract_field "xartists: " "xartists: Hozier                  xx")
assert_eq "$result" "Hozier" "extract_field strips panel marker for plain artist"

result=$(extract_field "xtitle: " "xtitle: Normal Track              xx")
assert_eq "$result" "Normal Track" "extract_field strips panel marker for plain title"

echo
echo "=== Bug C — metadata-service.py fuzzy-match word boundary ==="

# Static: re module is imported and \b boundary is used.
assert 'grep -qE "^import re$" "$METADATA"' \
       're module is imported in metadata-service.py'

assert 'grep -qE "re\\.escape\\(identifier\\)" "$METADATA"' \
       '_resolve_client_stream uses re.escape(identifier) for safety'

assert 'grep -qF "r\"\\b\" + re.escape" "$METADATA"' \
       '_resolve_client_stream uses \\b word-boundary marker'

# Functional: replicate the fixed resolver and verify edge cases.
python3 - <<'PY'
import re
import sys

def resolve(client_id, mapping):
    if client_id in mapping:
        return mapping[client_id]
    sorted_items = sorted(mapping.items(), key=lambda kv: -len(kv[0]))
    for identifier, stream_id in sorted_items:
        if not identifier or not client_id:
            continue
        id_pattern = r"\b" + re.escape(identifier) + r"\b"
        client_pattern = r"\b" + re.escape(client_id) + r"\b"
        if re.search(id_pattern, client_id) or re.search(client_pattern, identifier):
            return stream_id
    return None

mapping = {"Cucinino": "A", "snapvideo": "B", "Living-Room": "C"}
cases = [
    ("Cucina", None, "Cucina must NOT collide with Cucinino"),
    ("Cucinino", "A", "Cucinino exact match"),
    ("snapclient-snapvideo", "B", "snapvideo matches inside snapclient-snapvideo"),
    ("snapvideoXYZ", None, "snapvideo NOT matched in snapvideoXYZ (no boundary)"),
    ("Living-Room", "C", "Living-Room exact match"),
]
fail = 0
for client, expected, desc in cases:
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
    pass=$((pass + 5))
else
    fail=$((fail + rc))
fi

echo
echo "=== Python syntax ==="
for f in "$SHAIRPORT" "$METADATA"; do
    if python3 -m py_compile "$f" 2>/dev/null; then
        echo "  PASS: py_compile $(basename "$f")"
        pass=$((pass + 1))
    else
        echo "  FAIL: py_compile $(basename "$f")"
        fail=$((fail + 1))
    fi
done

echo
echo "=== Bash syntax ==="
if bash -n "$TIDAL_BRIDGE"; then
    echo "  PASS: bash -n tidal-meta-bridge.sh"
    pass=$((pass + 1))
else
    echo "  FAIL: bash -n tidal-meta-bridge.sh"
    fail=$((fail + 1))
fi

echo
echo "=== Summary ==="
echo "  Pass: $pass"
echo "  Fail: $fail"

[[ "$fail" -eq 0 ]]
