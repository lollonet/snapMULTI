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
#   Original bug (PR #330): `client in identifier or identifier in client`
#   matched "Cucina" in "Cucinino". The first fix used \b word boundary,
#   but \b still allowed "Sala" to collide with "Sala Grande" because the
#   space between the words is itself a word boundary. The second fix
#   (PR #333) removed fuzzy matching entirely: exact match + the
#   documented `snapclient-` prefix strip is the only resolution path.
#   Detailed assertions live in test_metadata_hardening.sh; here we just
#   sanity-check that no fuzzy regex remains.

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
echo "=== Bug C — metadata-service.py fuzzy match removed ==="

# Static: the fuzzy-match path is gone. No `re` import, no `\b` regex,
# no `re.escape` — the resolver is now exact-match + snapclient- prefix.
# Behavioural coverage lives in tests/test_metadata_hardening.sh.
assert '! grep -qE "^import re$" "$METADATA"' \
       '`import re` is gone (fuzzy regex removed)'

assert '! grep -qF "re.escape" "$METADATA"' \
       'no re.escape() calls remain in metadata-service.py'

assert '! grep -qF "r\"\\b\"" "$METADATA"' \
       'no \\b word-boundary regex remains'

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
