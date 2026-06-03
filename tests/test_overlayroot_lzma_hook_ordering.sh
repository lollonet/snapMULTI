#!/usr/bin/env bash
# Pin the install-order invariant introduced by PR #592:
#
#   install_initramfs_lzma_hook  →  raspi-config nonint do_overlayfs 0
#
# Pre-PR #592 the order was reversed:
#   raspi-config nonint do_overlayfs 0  →  install_initramfs_lzma_hook
#                                       →  ensure_overlayroot_initramfs_ready
# The trailing helper re-ran `update-initramfs -u -k all` so the hook
# installed in the second step would actually land in /boot/firmware/
# initramfs*. That second pass collided with the read-only finalize step
# remounting /boot/firmware ro, producing the cosmetic
#   cp: cannot create regular file '/boot/firmware/initramfs8': Read-only file system
# warnings the operator chased on every reflash.
#
# PR #592 moves the hook install BEFORE raspi-config. raspi-config's
# internal `update-initramfs -c -k all` then picks up the hook on its
# first pass — no second rebuild needed — and ensure_overlayroot_initramfs_ready
# (plus the two private helpers it drove, `_initramfs_target_for_kver`
# and `_initramfs_already_has_liblzma`) was deleted from
# scripts/common/overlayroot-lifecycle.sh.
#
# This test pins both halves of the contract in all three callers
# (system-tune.sh, client setup.sh, ro-mode.sh) so a future revert of
# the order surfaces in CI before reaching a device.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LIB="$REPO_ROOT/scripts/common/overlayroot-lifecycle.sh"
TUNE="$REPO_ROOT/scripts/common/system-tune.sh"
CLIENT_SETUP="$REPO_ROOT/client/common/scripts/setup.sh"
RO_MODE="$REPO_ROOT/client/common/scripts/ro-mode.sh"

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

assert_order() {
    local file="$1" first="$2" second="$3" desc="$4"
    local first_line second_line
    first_line=$(grep -nE "$first" "$file" | head -1 | cut -d: -f1)
    second_line=$(grep -nE "$second" "$file" | head -1 | cut -d: -f1)
    if [[ -n "$first_line" && -n "$second_line" ]] \
        && (( first_line < second_line )); then
        echo "  PASS: $desc (line $first_line precedes line $second_line)"
        pass=$((pass + 1))
    else
        echo "  FAIL: $desc"
        echo "        first  ($first):  line ${first_line:-<not found>}"
        echo "        second ($second): line ${second_line:-<not found>}"
        fail=$((fail + 1))
    fi
}

echo "== library: dead helpers removed =="

assert '! grep -qE "^ensure_overlayroot_initramfs_ready\\(\\)" "$LIB"' \
    "ensure_overlayroot_initramfs_ready removed from overlayroot-lifecycle.sh"
assert '! grep -qE "^_initramfs_target_for_kver\\(\\)" "$LIB"' \
    "_initramfs_target_for_kver removed (private helper, only driver was the above)"
assert '! grep -qE "^_initramfs_already_has_liblzma\\(\\)" "$LIB"' \
    "_initramfs_already_has_liblzma removed (private helper, only driver was the above)"
# install_initramfs_lzma_hook MUST stay — it's the contract.
assert 'grep -qE "^install_initramfs_lzma_hook\\(\\)" "$LIB"' \
    "install_initramfs_lzma_hook retained (still the contract)"

echo
echo "== library: post-fixup hardening helpers =="

# Hook install must defensively mkdir the hook directory — minimal/
# stripped staging may not have initramfs-tools installed.
assert 'grep -qE "mkdir -p .*hook_dst|mkdir -p .*\\\$\\(dirname" "$LIB"' \
    "install_initramfs_lzma_hook ensures hook directory exists (mkdir -p)"

# refresh_overlayroot_modules_dep replaces the depmod loop that
# ensure_overlayroot_initramfs_ready used to drive. Without it, the
# snapdigi-class failure (overlay module unloadable with 204-byte
# truncated modules.dep on next-boot kernel) is no longer covered.
assert 'grep -qE "^refresh_overlayroot_modules_dep\\(\\)" "$LIB"' \
    "refresh_overlayroot_modules_dep helper exists (depmod safety net retained)"
assert 'grep -qE "depmod -a \"\\\$kver\"" "$LIB"' \
    "refresh_overlayroot_modules_dep loops depmod -a per kver"
# Must NOT re-introduce update-initramfs in the library.
assert '! grep -qE "^[[:space:]]+update-initramfs -u -k" "$LIB"' \
    "no update-initramfs second-pass resurrection in library"

echo
echo "== callers: install_initramfs_lzma_hook BEFORE raspi-config =="

# Regex anchors on the actual CALL syntax (`install_initramfs_lzma_hook "$VAR"`)
# rather than the function name alone — the latter also matches header
# comments and would let a future revert pass silently if the comment
# referenced the function name above the call site.
assert_order "$TUNE" \
    '^[[:space:]]+install_initramfs_lzma_hook[[:space:]]+"' \
    'raspi-config nonint do_overlayfs 0' \
    "scripts/common/system-tune.sh CALLS hook before raspi-config"

assert_order "$CLIENT_SETUP" \
    '^[[:space:]]+install_initramfs_lzma_hook[[:space:]]+"' \
    'raspi-config nonint do_overlayfs 0' \
    "client/common/scripts/setup.sh CALLS hook before raspi-config"

assert_order "$RO_MODE" \
    '^[[:space:]]+install_initramfs_lzma_hook[[:space:]]+"' \
    'raspi-config nonint do_overlayfs 0' \
    "client/common/scripts/ro-mode.sh CALLS hook before raspi-config"

echo
echo "== callers: refresh_overlayroot_modules_dep BEFORE raspi-config =="

# The depmod safety net must run before raspi-config's update-initramfs
# in every caller. Tests anchor on the actual call, not the function
# name in comments, so a comment-rearrange revert is caught.
assert_order "$TUNE" \
    '^[[:space:]]+refresh_overlayroot_modules_dep' \
    'raspi-config nonint do_overlayfs 0' \
    "scripts/common/system-tune.sh CALLS depmod helper before raspi-config"

assert_order "$CLIENT_SETUP" \
    '^[[:space:]]+refresh_overlayroot_modules_dep' \
    'raspi-config nonint do_overlayfs 0' \
    "client/common/scripts/setup.sh CALLS depmod helper before raspi-config"

assert_order "$RO_MODE" \
    '^[[:space:]]+refresh_overlayroot_modules_dep' \
    'raspi-config nonint do_overlayfs 0' \
    "client/common/scripts/ro-mode.sh CALLS depmod helper before raspi-config"

echo
echo "== callers: no residual ensure_overlayroot_initramfs_ready =="

# Whole-tree sweep: no production code path may still call the deleted
# helper. The library file (overlayroot-lifecycle.sh) still mentions
# the name in its top-of-file "removed" documentation block — that's
# the only allowed match. Distinguish by checking that every grep hit
# is on a comment line (`^[[:space:]]*#`). PR #592 claude-review LOW:
# the earlier `residual=…` variable was assigned and never read; the
# real check is this loop. Inlined the loop to keep the intent obvious.
fail_residual=0
for f in "$TUNE" "$CLIENT_SETUP" "$RO_MODE" "$LIB"; do
    if grep -nE "ensure_overlayroot_initramfs_ready" "$f" \
        | grep -vE "^[0-9]+:[[:space:]]*#" >/dev/null 2>&1; then
        echo "  FAIL: residual uncommented ensure_overlayroot_initramfs_ready in $f"
        fail_residual=$((fail_residual + 1))
    fi
done
if (( fail_residual == 0 )); then
    echo "  PASS: no uncommented residual ensure_overlayroot_initramfs_ready calls"
    pass=$((pass + 1))
else
    fail=$((fail + fail_residual))
fi

echo
echo "Results: $pass passed, $fail failed"
exit $(( fail > 0 ? 1 : 0 ))
