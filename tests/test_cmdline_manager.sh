#!/usr/bin/env bash
# Functional + static checks for scripts/common/cmdline-manager.sh.
#
# Each helper is exercised against a tmpfile that mimics
# /boot/firmware/cmdline.txt. The check_cmdline_path tests are skipped
# unless we can shadow the system path lookup — instead we use a
# wrapper variable to point the helper at the tmpfile. Since the
# helper does `for candidate in /boot/firmware/cmdline.txt /boot/cmdline.txt`,
# we monkey-patch `cmdline_path` to return our tmpfile.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CMDLINE_MGR="$SCRIPT_DIR/../scripts/common/cmdline-manager.sh"

pass=0
fail=0

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

assert_contains() {
    local haystack="$1" needle="$2" desc="$3"
    if grep -qF -- "$needle" <<<"$haystack"; then
        echo "  PASS: $desc"
        pass=$((pass + 1))
    else
        echo "  FAIL: $desc (missing '$needle' in '$haystack')"
        fail=$((fail + 1))
    fi
}

assert_not_contains() {
    local haystack="$1" needle="$2" desc="$3"
    if ! grep -qF -- "$needle" <<<"$haystack"; then
        echo "  PASS: $desc"
        pass=$((pass + 1))
    else
        echo "  FAIL: $desc (unexpected '$needle' in '$haystack')"
        fail=$((fail + 1))
    fi
}

# Static checks first — these don't require shadowing.
echo "=== Static checks ==="
assert_eq "$(test -f "$CMDLINE_MGR" && echo yes)" "yes" "cmdline-manager.sh exists"
assert_eq "$(bash -n "$CMDLINE_MGR" 2>&1 && echo OK)" "OK" "bash -n clean"
if command -v shellcheck >/dev/null 2>&1; then
    assert_eq "$(shellcheck -S warning "$CMDLINE_MGR" >/dev/null 2>&1 && echo OK)" "OK" "shellcheck -S warning clean"
fi
for fn in cmdline_path cmdline_ensure_overlayroot cmdline_remove_overlayroot \
          cmdline_ensure_memory_cgroup cmdline_ensure_console_tty1 \
          cmdline_remove_token cmdline_remove_pattern cmdline_add_token; do
    assert_eq "$(grep -cE "^${fn}\\(\\) \\{" "$CMDLINE_MGR")" "1" "function $fn defined"
done

echo
echo "=== Functional setup ==="

# shellcheck source=../scripts/common/cmdline-manager.sh
source "$CMDLINE_MGR"

# Monkey-patch cmdline_path to return our tmpfile.
TMP_CMDLINE=$(mktemp /tmp/snapmulti-cmdline-test.XXXXXX)
trap 'rm -f "$TMP_CMDLINE"' EXIT
cmdline_path() {
    printf '%s\n' "$TMP_CMDLINE"
}

# ── Field-based helpers run on ALL platforms (no sed) ─────────────
echo
echo "=== Functional checks: cmdline_remove_token / _pattern / _add_token ==="

# Input validation.
if cmdline_remove_token "" 2>/dev/null; then
    echo "  FAIL: cmdline_remove_token should reject empty token"; fail=$((fail + 1))
else
    echo "  PASS: cmdline_remove_token rejects empty token"; pass=$((pass + 1))
fi
if cmdline_add_token "two words" 2>/dev/null; then
    echo "  FAIL: cmdline_add_token should reject whitespace token"; fail=$((fail + 1))
else
    echo "  PASS: cmdline_add_token rejects whitespace token"; pass=$((pass + 1))
fi

# Exact-field remove with punctuation tokens.
echo "console=tty1 fbcon=map:9 quiet splash root=PARTUUID=abc-02" > "$TMP_CMDLINE"
cmdline_remove_token 'fbcon=map:9'
assert_not_contains "$(cat "$TMP_CMDLINE")" "fbcon=map:9" "remove_token strips punctuation token fbcon=map:9"
assert_contains "$(cat "$TMP_CMDLINE")" "console=tty1" "remove_token preserves siblings (console=tty1)"
assert_contains "$(cat "$TMP_CMDLINE")" "root=PARTUUID=abc-02" "remove_token preserves siblings (root=PARTUUID)"

# Idempotent on missing.
cmdline_remove_token 'fbcon=map:9'
assert_not_contains "$(cat "$TMP_CMDLINE")" "fbcon=map:9" "remove_token idempotent when absent"

# Multiple sequential calls.
echo "quiet splash console=tty1 fbcon=map:9 rootwait" > "$TMP_CMDLINE"
cmdline_remove_token quiet
cmdline_remove_token splash
cmdline_remove_token 'fbcon=map:9'
result=$(cat "$TMP_CMDLINE")
assert_not_contains "$result" "quiet" "sequential remove_token: quiet gone"
assert_not_contains "$result" "splash" "sequential remove_token: splash gone"
assert_not_contains "$result" "fbcon=map:9" "sequential remove_token: fbcon gone"
assert_contains "$result" "console=tty1" "sequential remove_token: console preserved"
assert_contains "$result" "rootwait" "sequential remove_token: rootwait preserved"

# Pattern remove for parametric values.
echo "console=tty1 video=HDMI-A-1:1920M@60 quiet" > "$TMP_CMDLINE"
cmdline_remove_pattern 'video=HDMI-A-1:.*'
assert_not_contains "$(cat "$TMP_CMDLINE")" "video=HDMI-A-1" "remove_pattern strips parametric video= token"
assert_contains "$(cat "$TMP_CMDLINE")" "console=tty1" "remove_pattern preserves siblings"

# add_token: append + idempotent.
echo "console=tty1 quiet" > "$TMP_CMDLINE"
cmdline_add_token 'newflag=1'
assert_contains "$(cat "$TMP_CMDLINE")" "newflag=1" "add_token appends new token"
cmdline_add_token 'newflag=1'
count=$(grep -oE 'newflag=1' "$TMP_CMDLINE" | wc -l | tr -d ' ')
assert_eq "$count" "1" "add_token idempotent (no duplicate)"

# add_token preserves existing siblings exactly.
echo "alpha beta gamma" > "$TMP_CMDLINE"
cmdline_add_token delta
result=$(cat "$TMP_CMDLINE")
assert_eq "$(tr -d '\n' <<<"$result")" "alpha beta gamma delta" "add_token preserves order + appends"

# ── Legacy sed-based helpers ──────────────────────────────────────
echo
echo "=== Legacy sed-based functional checks (Linux only) ==="

# Helpers below use `sed -i 'pat' file`, which is GNU sed semantics
# (Linux, the production target). BSD sed (macOS default) interprets
# the second arg as the backup suffix and corrupts the test. Skip
# this block on Darwin unless `gsed` is available; CI runners are
# Linux and exercise the real path.
if [[ "$(uname -s)" == "Darwin" ]] && ! command -v gsed >/dev/null 2>&1; then
    echo "  SKIP: BSD sed on macOS — legacy sed helper tests run on Linux CI only"
    echo
    echo "Results: $pass passed, $fail failed"
    exit $(( fail > 0 ? 1 : 0 ))
fi

PI_OS_DEFAULT='coherent_pool=1M 8250.nr_uarts=1 console=serial0,115200 console=tty1 root=PARTUUID=abc-02 rootfstype=ext4 fsck.repair=yes rootwait quiet'

# --- overlayroot enable ---
echo "$PI_OS_DEFAULT" > "$TMP_CMDLINE"
cmdline_ensure_overlayroot
result=$(cat "$TMP_CMDLINE")
assert_contains "$result" "overlayroot=tmpfs" "ensure_overlayroot adds the token"
assert_eq "${result:0:18}" "overlayroot=tmpfs " "overlayroot=tmpfs is prepended (first 18 chars)"

# Idempotent re-run.
cmdline_ensure_overlayroot
count=$(grep -oE 'overlayroot=tmpfs' "$TMP_CMDLINE" | wc -l | tr -d ' ')
assert_eq "$count" "1" "ensure_overlayroot is idempotent (second call adds nothing)"

# --- overlayroot disable ---
cmdline_remove_overlayroot
result=$(cat "$TMP_CMDLINE")
assert_not_contains "$result" "overlayroot=tmpfs" "remove_overlayroot strips the token"

# Idempotent.
cmdline_remove_overlayroot
result=$(cat "$TMP_CMDLINE")
assert_not_contains "$result" "overlayroot=tmpfs" "remove_overlayroot is idempotent"

# Multi-space tolerance: prepend with extra spaces and remove must clean.
echo "  overlayroot=tmpfs   $PI_OS_DEFAULT  " > "$TMP_CMDLINE"
cmdline_remove_overlayroot
result=$(cat "$TMP_CMDLINE")
assert_not_contains "$result" "overlayroot=tmpfs" "remove_overlayroot handles multi-space surroundings"
# Cleanup leaves no leading / trailing / double spaces.
assert_eq "$(grep -cE '^  | {2,}| $' "$TMP_CMDLINE")" "0" "remove_overlayroot collapses whitespace"

# --- memory cgroup enable ---
echo "$PI_OS_DEFAULT" > "$TMP_CMDLINE"
cmdline_ensure_memory_cgroup
result=$(cat "$TMP_CMDLINE")
assert_contains "$result" "cgroup_enable=memory" "ensure_memory_cgroup adds enable token"
assert_contains "$result" "cgroup_memory=1" "ensure_memory_cgroup adds memory=1 token"

# Idempotent.
cmdline_ensure_memory_cgroup
count=$(grep -oE 'cgroup_enable=memory' "$TMP_CMDLINE" | wc -l | tr -d ' ')
assert_eq "$count" "1" "ensure_memory_cgroup is idempotent"

# --- console=tty1 defensive ---
# Default Pi OS already has it.
echo "$PI_OS_DEFAULT" > "$TMP_CMDLINE"
cmdline_ensure_console_tty1
count=$(grep -oE 'console=tty1' "$TMP_CMDLINE" | wc -l | tr -d ' ')
assert_eq "$count" "1" "ensure_console_tty1 is a no-op when already present"

# Strip it and re-add.
sed -i.bak 's/console=tty1 //g; s/console=tty1//g' "$TMP_CMDLINE"
rm -f "$TMP_CMDLINE.bak"
cmdline_ensure_console_tty1
result=$(cat "$TMP_CMDLINE")
assert_contains "$result" "console=tty1" "ensure_console_tty1 restores missing token"
count=$(grep -oE 'console=tty1' "$TMP_CMDLINE" | wc -l | tr -d ' ')
assert_eq "$count" "1" "ensure_console_tty1 added exactly one copy"

# --- cmdline_path miss returns non-zero ---
cmdline_path() {
    return 1
}
if cmdline_ensure_overlayroot 2>/dev/null; then
    echo "  FAIL: ensure_overlayroot should return non-zero when cmdline_path fails"
    fail=$((fail + 1))
else
    echo "  PASS: ensure_overlayroot returns non-zero when cmdline_path fails"
    pass=$((pass + 1))
fi

echo
echo "Results: $pass passed, $fail failed"
exit $(( fail > 0 ? 1 : 0 ))
