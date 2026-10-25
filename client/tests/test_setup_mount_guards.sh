#!/usr/bin/env bash
# Tests for setup.sh mount-state helpers (extracted via sed — setup.sh
# itself cannot be sourced, it runs the installer):
#   _mount_is_ro        — /boot/firmware ro detection. vfat's
#                         `errors=remount-ro` option must not count as ro.
#   _overlayroot_active — read-only mode (overlayroot on /) detection.
#   overlayroot guard   — setup.sh refuses to re-run while read-only mode
#                         is active unless --allow-overlayroot (or under
#                         firstboot, PROGRESS_MANAGED), never on first boot.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SETUP_SH="$SCRIPT_DIR/../common/scripts/setup.sh"

pass=0
fail=0

check() {
    local desc="$1"; shift
    if "$@"; then
        echo "  PASS: $desc"
        pass=$((pass + 1))
    else
        echo "  FAIL: $desc"
        fail=$((fail + 1))
    fi
}
check_not() {
    local desc="$1"; shift
    if "$@"; then
        echo "  FAIL: $desc"
        fail=$((fail + 1))
    else
        echo "  PASS: $desc"
        pass=$((pass + 1))
    fi
}

eval "$(sed -n '/^_mount_is_ro()/,/^}/p' "$SETUP_SH")"
eval "$(sed -n '/^_overlayroot_active()/,/^}/p' "$SETUP_SH")"
for fn in _mount_is_ro _overlayroot_active; do
    if ! declare -F "$fn" >/dev/null; then
        echo "  FAIL: $fn not found in $SETUP_SH"
        exit 1
    fi
done

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# /proc/mounts samples (Raspberry Pi OS Bookworm/Trixie).
cat > "$WORK/rw-boot" <<'EOF'
/dev/mmcblk0p2 / ext4 rw,noatime 0 0
devtmpfs /dev devtmpfs rw,relatime,size=1800000k,nr_inodes=450000,mode=755 0 0
/dev/mmcblk0p1 /boot/firmware vfat rw,relatime,fmask=0022,dmask=0022,codepage=437,iocharset=ascii,shortname=mixed,errors=remount-ro 0 0
EOF
cat > "$WORK/ro-boot-overlay" <<'EOF'
overlayroot / overlay rw,relatime,lowerdir=/media/root-ro,upperdir=/media/root-rw/overlay,workdir=/media/root-rw/overlay-workdir/_ 0 0
/dev/mmcblk0p2 /media/root-ro ext4 ro,relatime 0 0
tmpfs /media/root-rw tmpfs rw,relatime 0 0
/dev/mmcblk0p1 /boot/firmware vfat ro,relatime,fmask=0022,dmask=0022,codepage=437,iocharset=ascii,shortname=mixed,errors=remount-ro 0 0
EOF
cat > "$WORK/remounted-rw" <<'EOF'
/dev/mmcblk0p1 /boot/firmware vfat ro,relatime,errors=remount-ro 0 0
/dev/mmcblk0p1 /boot/firmware vfat rw,relatime,errors=remount-ro 0 0
EOF
cat > "$WORK/legacy-boot" <<'EOF'
/dev/mmcblk0p2 / ext4 rw,noatime 0 0
/dev/mmcblk0p1 /boot vfat rw,relatime,errors=remount-ro 0 0
EOF

echo "Testing _mount_is_ro..."
check_not "rw vfat with errors=remount-ro is NOT ro" _mount_is_ro /boot/firmware "$WORK/rw-boot"
check     "ro vfat (overlayroot install) is ro"      _mount_is_ro /boot/firmware "$WORK/ro-boot-overlay"
check_not "later rw remount wins over earlier ro"    _mount_is_ro /boot/firmware "$WORK/remounted-rw"
check_not "legacy /boot rw is NOT ro"                _mount_is_ro /boot "$WORK/legacy-boot"
check_not "dir that is not a mount point is NOT ro"  _mount_is_ro /boot/firmware "$WORK/legacy-boot"
check_not "prefix of another mount point is NOT matched" _mount_is_ro /boot "$WORK/ro-boot-overlay"

echo ""
echo "Testing _overlayroot_active..."
check_not "ext4 root (first boot / writable) → inactive" _overlayroot_active "$WORK/rw-boot"
check     "overlayroot on / → active"                    _overlayroot_active "$WORK/ro-boot-overlay"
check_not "unreadable mounts table → inactive"           _overlayroot_active "$WORK/missing"

echo ""
echo "Testing the overlayroot guard block..."
# Extract the guard (from `if _overlayroot_active /proc/mounts; then` to its closing
# `fi` at column 0) and run it with a stubbed detector.
GUARD="$WORK/guard.sh"
awk '/^if _overlayroot_active \/proc\/mounts; then$/ {c=1} c {print} c && /^fi$/ {exit}' "$SETUP_SH" > "$GUARD"
if [[ ! -s "$GUARD" ]]; then
    echo "  FAIL: overlayroot guard block not found in setup.sh"
    exit 1
fi

run_guard() {
    local active="$1" allow="$2" managed="$3"
    (
        if [[ "$active" == yes ]]; then
            _overlayroot_active() { return 0; }
        else
            _overlayroot_active() { return 1; }
        fi
        # shellcheck disable=SC2034  # read by the sourced guard block
        ALLOW_OVERLAYROOT="$allow"
        # shellcheck disable=SC2034  # read by the sourced guard block
        PROGRESS_MANAGED="$managed"
        # shellcheck source=/dev/null
        source "$GUARD"
        echo "CONTINUED"
    ) 2>&1
}

out=$(run_guard no false "")
check "overlay inactive (first boot) → continues" grep -q CONTINUED <<<"$out"
out=$(run_guard yes false "" || true)
check_not "overlay active, interactive re-run → refused" grep -q CONTINUED <<<"$out"
check "refusal points to 'ro-mode disable'" grep -q "ro-mode disable" <<<"$out"
out=$(run_guard yes true "")
check "overlay active + --allow-overlayroot → continues" grep -q CONTINUED <<<"$out"
out=$(run_guard yes false 1)
check "overlay active under firstboot (PROGRESS_MANAGED) → warns, continues" grep -q CONTINUED <<<"$out"

check "--allow-overlayroot is parsed" grep -q -- '--allow-overlayroot)' "$SETUP_SH"
check "boot remount uses _mount_is_ro (no word-boundary grep on mount output)" \
    grep -q '_mount_is_ro "$_boot_dir"' "$SETUP_SH"

echo ""
if [[ "$fail" -gt 0 ]]; then
    echo "FAILED: $fail tests failed, $pass passed"
    exit 1
fi
echo "All $pass tests passed!"
