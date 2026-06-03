#!/usr/bin/env bash
# Unit + static tests for scripts/common/path-resolve.sh.
#
# Coverage:
#   - resolve_first_existing_file: found, not-found, first-of-many, missing-vars
#   - resolve_first_existing_dir: same matrix
#   - Migration pinning: firstboot.sh + setup.sh source the lib and call
#     the helpers; intentionally-inline patterns documented inline.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LIB="$REPO_ROOT/scripts/common/path-resolve.sh"
FIRSTBOOT="$REPO_ROOT/scripts/firstboot.sh"
SETUP="$REPO_ROOT/client/common/scripts/setup.sh"

# shellcheck source=/dev/null
source "$LIB"

pass=0
fail=0

assert_eq() {
    local got="$1" want="$2" desc="$3"
    if [[ "$got" == "$want" ]]; then
        echo "  PASS: $desc"
        pass=$((pass + 1))
    else
        echo "  FAIL: $desc"
        echo "         got:  '$got'"
        echo "         want: '$want'"
        fail=$((fail + 1))
    fi
}

assert_rc() {
    local rc="$1" want="$2" desc="$3"
    if [[ "$rc" == "$want" ]]; then
        echo "  PASS: $desc"
        pass=$((pass + 1))
    else
        echo "  FAIL: $desc (rc=$rc, want=$want)"
        fail=$((fail + 1))
    fi
}

note_pass() { echo "  PASS: $1"; pass=$((pass + 1)); }
note_fail() { echo "  FAIL: $1"; fail=$((fail + 1)); }

echo "=== resolve_first_existing_file ==="
sandbox=$(mktemp -d "${TMPDIR:-/tmp}/snapmulti-path-resolve-XXXXXX")
trap 'rm -rf "$sandbox"' EXIT
mkdir -p "$sandbox/a" "$sandbox/b" "$sandbox/c"
echo "target" > "$sandbox/b/target.sh"

GOT=""
resolve_first_existing_file GOT "target.sh" "$sandbox/a" "$sandbox/b" "$sandbox/c"
rc=$?
assert_eq "$GOT" "$sandbox/b/target.sh" "first match returned (b/target.sh)"
assert_rc "$rc" 0 "rc=0 on found"

GOT=""
resolve_first_existing_file GOT "missing.sh" "$sandbox/a" "$sandbox/b" "$sandbox/c" || rc=$?
assert_eq "$GOT" "" "no match -> VAR_NAME cleared"
assert_rc "$rc" 1 "rc=1 on not-found"

# First-of-many semantics: target.sh exists in both b/ and c/, b wins.
echo "target-c" > "$sandbox/c/target.sh"
GOT=""
resolve_first_existing_file GOT "target.sh" "$sandbox/a" "$sandbox/b" "$sandbox/c"
assert_eq "$GOT" "$sandbox/b/target.sh" "first-of-many: b/ wins over c/"

# Single candidate
GOT=""
resolve_first_existing_file GOT "target.sh" "$sandbox/b"
assert_eq "$GOT" "$sandbox/b/target.sh" "single candidate, exists"

# Empty candidate list (no dirs after var+filename) → not found
GOT="prior"
rc=0
resolve_first_existing_file GOT "target.sh" || rc=$?
assert_eq "$GOT" "" "empty candidate list -> VAR_NAME cleared"
assert_rc "$rc" 1 "empty candidate list -> rc=1"

echo
echo "=== resolve_first_existing_dir ==="
GOT=""
resolve_first_existing_dir GOT "$sandbox/zz" "$sandbox/b" "$sandbox/c"
rc=$?
assert_eq "$GOT" "$sandbox/b" "first existing dir returned (b)"
assert_rc "$rc" 0 "rc=0 on found"

GOT=""
resolve_first_existing_dir GOT "$sandbox/zz" "$sandbox/yy" || rc=$?
assert_eq "$GOT" "" "no dir matches -> VAR_NAME cleared"
assert_rc "$rc" 1 "rc=1 on not-found"

# Files-as-dirs negative case
GOT=""
resolve_first_existing_dir GOT "$sandbox/b/target.sh" "$sandbox/c" || true
assert_eq "$GOT" "$sandbox/c" "file path is NOT a dir -> skip to next candidate"

echo
echo "=== Migration pinning — firstboot.sh ==="
if grep -qE "^source \"\\\$COMMON/path-resolve\\.sh\"" "$FIRSTBOOT"; then
    note_pass "firstboot.sh sources path-resolve.sh"
else
    note_fail "firstboot.sh does NOT source path-resolve.sh"
fi

helper_calls=$(grep -cE "resolve_first_existing_file\\b" "$FIRSTBOOT" || true)
if (( helper_calls >= 7 )); then
    note_pass "firstboot.sh calls resolve_first_existing_file >=7 times (got $helper_calls)"
else
    note_fail "firstboot.sh expected >=7 helper calls, got $helper_calls"
fi

# 2 residual inline patterns intentionally stay (STATUS_DIR + BIND_DIR
# are multi-file dir gates, not single-file resolves). Pin the count
# so a future helper that supports multi-file gates can be wired in.
residual=$(grep -cE "for _[a-z_]*candidate.*in" "$FIRSTBOOT" || true)
if (( residual == 2 )); then
    note_pass "firstboot.sh has 2 intentional residuals (STATUS_DIR + BIND_DIR multi-file dir gates)"
else
    note_fail "firstboot.sh expected 2 residual loops, got $residual"
fi

echo
echo "=== Migration pinning — setup.sh ==="
if grep -qE "source \"\\\$COMMON_MODULE_DIR/path-resolve\\.sh\"" "$SETUP"; then
    note_pass "setup.sh sources path-resolve.sh (guarded)"
else
    note_fail "setup.sh does NOT source path-resolve.sh"
fi

helper_calls=$(grep -cE "resolve_first_existing_file\\b" "$SETUP" || true)
if (( helper_calls >= 5 )); then
    note_pass "setup.sh calls resolve_first_existing_file >=5 times (got $helper_calls)"
else
    note_fail "setup.sh expected >=5 helper calls, got $helper_calls"
fi

# Each call site keeps an inline `for ... candidate in` fallback wrapped
# in `if declare -F resolve_first_existing_file ... else` — preserves
# behaviour on legacy stripped bundles that don't ship path-resolve.sh.
fallback_count=$(grep -cE "declare -F resolve_first_existing_file" "$SETUP" || true)
if (( fallback_count >= 5 )); then
    note_pass "setup.sh keeps legacy-fallback wrapper at every helper site (got $fallback_count)"
else
    note_fail "setup.sh expected >=5 fallback wrappers, got $fallback_count"
fi

echo
echo "Results: $pass passed, $fail failed"
exit $(( fail > 0 ? 1 : 0 ))
