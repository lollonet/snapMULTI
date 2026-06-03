#!/usr/bin/env bash
# Unit + static tests for scripts/common/install-conf-reader.sh.
#
# Coverage:
#   - install_conf_get: present/absent/duplicate field, all strip
#     modes (all/cr/none), bad mode → rc 1, values with `=` inside,
#     missing file
#   - Migration pinning: firstboot.sh sources the helper early
#     (before line 200), all 12 inline parse sites migrated, no
#     residual `grep ... install.conf ... cut -d=` patterns

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LIB="$REPO_ROOT/scripts/common/install-conf-reader.sh"
FIRSTBOOT="$REPO_ROOT/scripts/firstboot.sh"

# shellcheck source=/dev/null
source "$LIB"

pass=0
fail=0

note_pass() { echo "  PASS: $1"; pass=$((pass + 1)); }
note_fail() { echo "  FAIL: $1"; fail=$((fail + 1)); }

assert_eq() {
    local got="$1" want="$2" desc="$3"
    if [[ "$got" == "$want" ]]; then
        note_pass "$desc"
    else
        note_fail "$desc (got='$got' want='$want')"
    fi
}

sandbox=$(mktemp -d "${TMPDIR:-/tmp}/snapmulti-conf-XXXXXX")
trap 'rm -rf "$sandbox"' EXIT

# Build a fixture install.conf covering every edge case.
cat > "$sandbox/install.conf" <<'EOF'
INSTALL_TYPE=server
HOSTNAME=  pi-server
MUSIC_SOURCE=nfs
NFS_SERVER=nas.local
SMB_USER=alice
SMB_PASS=p@ss=word with spaces
DUPLICATE_KEY=first
DUPLICATE_KEY=second
PASSWORD_WITH_CR=secret\r
EMPTY_VALUE=
EOF
# embed a literal CR after EMPTY_VALUE for the CR-strip test
printf 'CR_FIELD=value-with-cr\r\n' >> "$sandbox/install.conf"

echo "=== install_conf_get — present field, default strip (all) ==="
assert_eq "$(install_conf_get INSTALL_TYPE "$sandbox/install.conf")" \
          "server" "INSTALL_TYPE returns 'server'"

# Leading whitespace stripped under default mode
assert_eq "$(install_conf_get HOSTNAME "$sandbox/install.conf")" \
          "pi-server" "HOSTNAME (leading spaces) → stripped"

echo
echo "=== install_conf_get — absent field ==="
assert_eq "$(install_conf_get NONEXISTENT "$sandbox/install.conf")" \
          "" "missing field returns empty string"

echo
echo "=== install_conf_get — missing file ==="
assert_eq "$(install_conf_get INSTALL_TYPE "/nonexistent/path")" \
          "" "missing file returns empty (no error)"

echo
echo "=== install_conf_get — duplicate keys, first wins ==="
assert_eq "$(install_conf_get DUPLICATE_KEY "$sandbox/install.conf")" \
          "first" "duplicate key: first match wins (grep -m1)"

echo
echo "=== install_conf_get — value with '=' inside (cut -d= -f2-) ==="
assert_eq "$(install_conf_get SMB_PASS "$sandbox/install.conf" cr)" \
          "p@ss=word with spaces" "SMB_PASS preserves '=' and spaces under cr mode"

echo
echo "=== install_conf_get — cr mode preserves spaces, strips \\r ==="
assert_eq "$(install_conf_get CR_FIELD "$sandbox/install.conf" cr)" \
          "value-with-cr" "CR field with literal \\r → stripped"

echo
echo "=== install_conf_get — none mode preserves everything ==="
got=$(install_conf_get HOSTNAME "$sandbox/install.conf" none)
# none mode keeps leading whitespace (from "  pi-server")
if [[ "$got" == *"pi-server"* ]] && [[ "$got" != "pi-server" ]]; then
    note_pass "HOSTNAME none mode: preserves leading whitespace"
else
    note_fail "HOSTNAME none mode: got='$got' (expected leading whitespace preserved)"
fi

echo
echo "=== install_conf_get — unknown strip mode → rc 1 ==="
rc=0
install_conf_get INSTALL_TYPE "$sandbox/install.conf" garbage >/dev/null 2>&1 || rc=$?
if [[ "$rc" == "1" ]]; then
    note_pass "unknown strip mode 'garbage' → rc=1"
else
    note_fail "unknown strip mode: rc=$rc (expected 1)"
fi

echo
echo "=== install_conf_get — invalid field name rejected (no regex injection) ==="
# Reviewer suggested `grep -F` to make the pattern literal, but `-F`
# also treats the leading `^` as literal — losing the start-of-line
# anchor. Verified: `printf '^FOO=x\nFOO=y\n' | grep -F '^FOO='` matches
# the literal-caret line, not FOO=y. Instead we input-validate the
# FIELD as a shell-style identifier so the regex stays intact.
for bad in "FOO.BAR" "FOO BAR" "FOO/BAR" "" "1FOO" "FOO[BAR]" "FOO|BAR"; do
    rc=0
    install_conf_get "$bad" "$sandbox/install.conf" >/dev/null 2>&1 || rc=$?
    if [[ "$rc" == "1" ]]; then
        note_pass "invalid field name '$bad' → rc=1 (regex injection blocked)"
    else
        note_fail "invalid field name '$bad' → rc=$rc (expected 1)"
    fi
done

# Valid identifiers still work
for good in "FOO" "FOO_BAR" "Foo" "_underscore_start" "F1" "X_2_Y"; do
    rc=0
    install_conf_get "$good" "$sandbox/install.conf" >/dev/null 2>&1 || rc=$?
    if [[ "$rc" == "0" ]]; then
        note_pass "valid identifier '$good' accepted"
    else
        note_fail "valid identifier '$good' → rc=$rc (expected 0)"
    fi
done

echo
echo "=== install_conf_get — empty value ==="
assert_eq "$(install_conf_get EMPTY_VALUE "$sandbox/install.conf")" \
          "" "EMPTY_VALUE (just '=' then nothing) returns empty"

echo
echo "=== Migration pinning — firstboot.sh ==="

# Helper must be sourced. The early-source pattern (right after
# SNAP_BOOT is defined) is required because the install.conf parse
# block runs before the bulk-source section ~line 260.
if grep -qE 'source "\$SNAP_BOOT/common/install-conf-reader\.sh"' "$FIRSTBOOT"; then
    note_pass "firstboot.sh sources install-conf-reader.sh early (via \$SNAP_BOOT)"
else
    note_fail "firstboot.sh missing early source 'source \"\$SNAP_BOOT/common/install-conf-reader.sh\"'"
fi

# Every old inline parse pattern must be gone. The signature pattern is
# `install.conf` followed by `cut -d=` somewhere on the same line.
residual=$(grep -cE 'install\.conf.*cut -d=' "$FIRSTBOOT" || true)
if (( residual == 0 )); then
    note_pass "firstboot.sh has 0 residual 'install.conf | cut -d=' parses"
else
    note_fail "firstboot.sh has $residual residual inline parses (should be 0)"
fi

# Helper call count: expect at least 11 (12 sites minus the early
# INSTALL_TYPE one is the canonical baseline; the test is generous to
# allow future docstring/comment additions).
calls=$(grep -cE 'install_conf_get\b' "$FIRSTBOOT" || true)
if (( calls >= 11 )); then
    note_pass "firstboot.sh has $calls install_conf_get calls (>= 11 expected)"
else
    note_fail "firstboot.sh has only $calls install_conf_get calls (expected >= 11)"
fi

# The inline `_rc()` local helper at line ~156 must be gone.
if ! grep -qE '^\s*_rc\(\)' "$FIRSTBOOT"; then
    note_pass "firstboot.sh inline _rc() helper removed (replaced by install_conf_get)"
else
    note_fail "firstboot.sh still has the inline _rc() local helper"
fi

# Source line must precede the first install_conf_get call (otherwise
# bash errors with "command not found" — line-by-line interpreter).
src_line=$(grep -nE 'source "\$SNAP_BOOT/common/install-conf-reader\.sh"' "$FIRSTBOOT" | head -1 | cut -d: -f1)
# `grep -n` prefixes lines with `NNN:` so the filter anchors after
# the colon: `:[[:space:]]*#` strips lines whose content starts with
# `#`. The previous `^\s*#` would never match (verified by PR #585 review).
first_call_line=$(grep -nE 'install_conf_get\b' "$FIRSTBOOT" | grep -vE ':[[:space:]]*#' | head -1 | cut -d: -f1)
if [[ -n "$src_line" && -n "$first_call_line" && "$src_line" -lt "$first_call_line" ]]; then
    note_pass "source line ($src_line) precedes first install_conf_get call ($first_call_line)"
else
    note_fail "ordering broken: source at $src_line, first call at $first_call_line"
fi

echo
echo "Results: $pass passed, $fail failed"
exit $(( fail > 0 ? 1 : 0 ))
