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
          "v7l suffix -> initramfs7l (Pi 3)"
assert_eq "$(_initramfs_target_for_kver '6.1.21+rpt-rpi-v7+')" \
          "/boot/firmware/initramfs7" \
          "v7+ suffix -> initramfs7 (Pi 2/3 32-bit)"
assert_eq "$(_initramfs_target_for_kver '6.1.21+rpt-rpi-v6+')" \
          "/boot/firmware/initramfs" \
          "v6+ suffix -> initramfs (Pi 1/Zero)"
assert_eq "$(_initramfs_target_for_kver 'totally-foreign-kver')" \
          "" \
          "unknown suffix -> empty (caller falls back to rebuild)"

echo
echo "=== _initramfs_already_has_liblzma — missing file ==="
_rc=0
_initramfs_already_has_liblzma "/nonexistent/initramfs" || _rc=$?
assert_rc "$_rc" 1 "missing target → false (conservative — rebuild)"

echo
echo "=== _initramfs_already_has_liblzma — pipefail + SIGPIPE regression ==="
# Real lsinitramfs streams ~10k entries from a ~12 MB cpio archive. With
# `set -euo pipefail`, the original `grep -qF` would exit at first match,
# send SIGPIPE to lsinitramfs (exit 141), and pipefail would propagate the
# 141 — the check returned false EVEN WHEN liblzma was present, and
# firstboot.sh re-ran update-initramfs against a now-ro /boot/firmware,
# logging the cosmetic "first boot may not activate overlay" WARN.
# This block reproduces the pipefail interaction with a fake lsinitramfs
# that emits lots of output BEFORE the matching line.
SANDBOX=$(mktemp -d -t initramfs-pipefail-XXXXXX)
trap 'rm -rf "$SANDBOX"' EXIT

# Fake lsinitramfs: stream many lines so grep -q would close the pipe
# well before the producer finishes.
mkdir -p "$SANDBOX/bin"
cat > "$SANDBOX/bin/lsinitramfs" <<'STUB'
#!/usr/bin/env bash
set -e
# Emit a long preamble, then the liblzma line, then more output to ensure
# any early-exit consumer triggers SIGPIPE on the producer.
for i in $(seq 1 5000); do
    echo "usr/lib/aarch64-linux-gnu/preamble-entry-${i}.so"
done
echo "usr/lib/aarch64-linux-gnu/liblzma.so.5"
for i in $(seq 1 5000); do
    echo "usr/lib/aarch64-linux-gnu/tail-entry-${i}.so"
done
STUB
chmod +x "$SANDBOX/bin/lsinitramfs"

touch "$SANDBOX/initramfs8"

# Verify the helper survives pipefail and returns success.
_rc=0
PATH="$SANDBOX/bin:$PATH" _initramfs_already_has_liblzma "$SANDBOX/initramfs8" || _rc=$?
assert_rc "$_rc" 0 "pipefail-safe: liblzma matched in streamed output (no SIGPIPE false-negative)"

# Negative case: absence still returns false.
cat > "$SANDBOX/bin/lsinitramfs" <<'STUB'
#!/usr/bin/env bash
set -e
for i in $(seq 1 1000); do
    echo "usr/lib/aarch64-linux-gnu/nothing-${i}.so"
done
STUB
chmod +x "$SANDBOX/bin/lsinitramfs"

_rc=0
PATH="$SANDBOX/bin:$PATH" _initramfs_already_has_liblzma "$SANDBOX/initramfs8" || _rc=$?
assert_rc "$_rc" 1 "pipefail-safe: liblzma absent → false (rebuild)"

# Static-shape assertion: guard the regression at source-level too — the
# pipeline must NOT use `grep -qF` (early exit + SIGPIPE) and MUST sink
# to >/dev/null so the producer drains cleanly.
if grep -nE 'lsinitramfs[^|]+\|[[:space:]]*grep -qF' "$LIB" >/dev/null 2>&1; then
    echo "  FAIL: helper still uses 'grep -qF' — re-introduces SIGPIPE pipefail bug"
    fail=$((fail + 1))
else
    echo "  PASS: helper does not use 'grep -qF' (SIGPIPE-safe form)"
    pass=$((pass + 1))
fi
if grep -nE 'lsinitramfs[^|]+\|[[:space:]]*grep -F[^|]+>/dev/null' "$LIB" >/dev/null 2>&1; then
    echo "  PASS: helper sinks grep output to /dev/null (producer drains cleanly)"
    pass=$((pass + 1))
else
    echo "  FAIL: helper missing >/dev/null sink — drain shape not guaranteed"
    fail=$((fail + 1))
fi

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
