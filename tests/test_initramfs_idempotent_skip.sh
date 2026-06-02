#!/usr/bin/env bash
# Pure-function unit tests for the idempotent-rebuild guard added to
# scripts/common/overlayroot-lifecycle.sh:
#   - _initramfs_target_for_kver  — kver → /boot/firmware path map
#   - _initramfs_already_has_liblzma — file presence + lsinitramfs check
#
# Static assertions on ensure_overlayroot_initramfs_ready confirm the
# skip path is wired correctly.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$SCRIPT_DIR/../scripts/common/overlayroot-lifecycle.sh"

# Stub the unified-log functions the lib expects so we can source it
# without the firstboot.sh harness. shellcheck cannot follow the indirect
# invocation from the sourced library, hence the disables.
# shellcheck disable=SC2329
info() { :; }
# shellcheck disable=SC2329
ok()   { :; }
# shellcheck disable=SC2329
warn() { :; }

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

echo "=== _initramfs_target_for_kver — kver suffix mapping ==="
assert_eq "$(_initramfs_target_for_kver '6.18.33+rpt-rpi-v8')" \
          "/boot/firmware/initramfs8" \
          "v8 suffix → initramfs8"
assert_eq "$(_initramfs_target_for_kver '6.18.33+rpt-rpi-2712')" \
          "/boot/firmware/initramfs_2712" \
          "2712 suffix → initramfs_2712"
assert_eq "$(_initramfs_target_for_kver '6.12.75+rpt-rpi-v8')" \
          "/boot/firmware/initramfs8" \
          "different kver, same v8 suffix → same path"
assert_eq "$(_initramfs_target_for_kver '6.18.33+rpt-rpi-v7l')" \
          "/boot/firmware/initramfs7l" \
          "v7l suffix → initramfs7l (Pi 3)"
assert_eq "$(_initramfs_target_for_kver 'totally-foreign-kver')" \
          "" \
          "unknown suffix → empty (caller falls back to rebuild)"

echo
echo "=== _initramfs_already_has_liblzma — missing file ==="
_rc=0
_initramfs_already_has_liblzma "/nonexistent/initramfs" || _rc=$?
assert_rc "$_rc" 1 "missing target → false (conservative — rebuild)"

echo
echo "=== Static wiring — ensure_overlayroot_initramfs_ready calls the skip path ==="
if grep -qE "_initramfs_already_has_liblzma" "$LIB"; then
    echo "  PASS: ensure_overlayroot_initramfs_ready references the idempotency check"
    pass=$((pass + 1))
else
    echo "  FAIL: ensure_overlayroot_initramfs_ready does not call _initramfs_already_has_liblzma"
    fail=$((fail + 1))
fi

# Skip path must `continue` (not return) — otherwise a single
# already-built kernel would short-circuit the loop and the next kver
# in /lib/modules would be skipped silently. Anchor on the if-block
# that gates the skip: from `if [[ -n "$target" ]] && _initramfs_…`
# down to the first `continue`.
skip_block=$(awk '/if \[\[ -n "\$target" \]\] && _initramfs_already_has_liblzma/{f=1} f{print; if (/continue/) exit}' "$LIB")
if grep -qE "^[[:space:]]+continue" <<<"$skip_block"; then
    echo "  PASS: skip path uses 'continue' (loop keeps iterating other kvers)"
    pass=$((pass + 1))
else
    echo "  FAIL: skip path does not 'continue' — could short-circuit other kvers"
    fail=$((fail + 1))
fi

# The check must come AFTER depmod (which is cheap and writes to
# rootfs, so it should always run) and BEFORE update-initramfs (the
# thing we're guarding).
depmod_line=$(grep -nE "depmod -a" "$LIB" | head -1 | cut -d: -f1)
liblzma_line=$(grep -nE "_initramfs_already_has_liblzma" "$LIB" | tail -1 | cut -d: -f1)
update_line=$(grep -nE "update-initramfs -u -k \"\\\$kver\"" "$LIB" | head -1 | cut -d: -f1)
if [[ -n "$depmod_line" && -n "$liblzma_line" && -n "$update_line" \
      && "$depmod_line" -lt "$liblzma_line" \
      && "$liblzma_line" -lt "$update_line" ]]; then
    echo "  PASS: ordering depmod → idempotency check → update-initramfs preserved"
    pass=$((pass + 1))
else
    echo "  FAIL: ordering broken (depmod=$depmod_line, check=$liblzma_line, update=$update_line)"
    fail=$((fail + 1))
fi

echo
echo "Results: $pass passed, $fail failed"
exit $(( fail > 0 ? 1 : 0 ))
