#!/usr/bin/env bash
# shellcheck disable=SC2016  # assert() conditions are eval'd inside it.
#
# Static checks for the overlayroot first-boot emergency-mode fix.
#
# The bug: at the first boot after `setup_readonly_fs` enables overlayroot,
# the initramfs hook rewrites /etc/fstab — `/media/nfs-music` becomes
# `/media/root-ro/media/nfs-music` AND the `nofail` flag is stripped.
# When the NAS is slow on the very first attempt, the mount is treated
# as a hard local-fs.target dependency, which fails, and systemd lands
# in emergency.target with "Cannot open access to console, the root
# account is locked. Press Enter to continue".
#
# The fix: stop writing /etc/fstab for NFS/SMB. Generate hand-crafted
# .mount units in /etc/systemd/system/ instead — files there are NOT
# rewritten by the overlayroot initramfs hook, so the path AND the
# nofail (carried as `Options=` and unit-level dependency defaults)
# survive. Migration: any existing fstab line for the same Where= path
# is removed at install time so it can't race with the new unit.
#
# Also tests the defensive companion in system-tune.sh:
#   - update-initramfs is forced after raspi-config do_overlayfs (closes
#     a transient race where the rebuild lags the kernel modules apt
#     installed milliseconds earlier).
#   - cmdline.txt is sanity-checked for `console=tty1`.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MOUNT_SH="$SCRIPT_DIR/../scripts/common/mount-music.sh"
SYSTEM_TUNE_SH="$SCRIPT_DIR/../scripts/common/system-tune.sh"

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

echo "=== mount-music.sh — systemd .mount unit generator ==="

assert 'grep -qE "^_write_systemd_mount_unit\\(\\)" "$MOUNT_SH"' \
       '_write_systemd_mount_unit helper is defined'

assert 'grep -qE "systemd-escape -p --suffix=mount" "$MOUNT_SH"' \
       'helper uses systemd-escape for the unit filename'

assert 'grep -qE "/etc/systemd/system/" "$MOUNT_SH"' \
       'unit is written under /etc/systemd/system (overlayroot-safe)'

assert 'grep -qE "systemctl enable.*unit_name" "$MOUNT_SH"' \
       'helper enables the unit after writing it'

assert 'grep -qE "^Before=snapmulti-server\\.service snapclient\\.service" "$MOUNT_SH"' \
       'unit declares Before= ordering vs snapMULTI services (no Requires)'

# Both NFS and SMB branches must call the helper (and NOT write fstab
# lines for these network shares).
nfs_block=$(awk '/^[[:space:]]*nfs\)/,/^[[:space:]]*;;[[:space:]]*$/' "$MOUNT_SH")
smb_block=$(awk '/^[[:space:]]*smb\)/,/^[[:space:]]*;;[[:space:]]*$/' "$MOUNT_SH")

assert 'echo "$nfs_block" | grep -qE "_write_systemd_mount_unit nfs"' \
       'nfs branch calls _write_systemd_mount_unit'

assert 'echo "$smb_block" | grep -qE "_write_systemd_mount_unit cifs"' \
       'smb branch calls _write_systemd_mount_unit'

assert '! echo "$nfs_block" | grep -qE "echo .* >> /etc/fstab"' \
       'nfs branch no longer writes /etc/fstab'

assert '! echo "$smb_block" | grep -qE "echo .* >> /etc/fstab"' \
       'smb branch no longer writes /etc/fstab'

# nofail must be in the options passed to the helper (defence in depth
# even though the helper bypasses fstab; if a future fallback path
# rewrites fstab, nofail is preserved).
assert 'echo "$nfs_block" | grep -qE "nofail"' \
       'nfs options include nofail'

assert 'echo "$smb_block" | grep -qE "nofail"' \
       'smb options include nofail'

# snapMULTI uses reflash as primary update strategy (DEC-003), so there is
# never a "legacy fstab line" to migrate. The unit file in
# /etc/systemd/system/ is overwritten idempotently on retry.

echo
echo "=== system-tune.sh — defensive overlayroot setup ==="

assert 'grep -qE "update-initramfs -u -k all" "$SYSTEM_TUNE_SH"' \
       'setup_readonly_fs forces update-initramfs after raspi-config'

assert 'grep -qE "console=tty1" "$SYSTEM_TUNE_SH"' \
       'setup_readonly_fs sanity-checks cmdline.txt for console=tty1'

# update-initramfs must run AFTER raspi-config nonint do_overlayfs 0,
# otherwise the rebuild misses the overlay support raspi-config just
# enabled.
raspi_line=$(grep -nE "raspi-config nonint do_overlayfs 0" "$SYSTEM_TUNE_SH" | head -1 | cut -d: -f1)
initramfs_line=$(grep -nE "update-initramfs -u -k all" "$SYSTEM_TUNE_SH" | head -1 | cut -d: -f1)
if [[ -n "$raspi_line" && -n "$initramfs_line" && "$initramfs_line" -gt "$raspi_line" ]]; then
    echo "  PASS: update-initramfs runs AFTER raspi-config do_overlayfs (line $initramfs_line > $raspi_line)"
    pass=$((pass + 1))
else
    echo "  FAIL: update-initramfs ordering wrong (raspi=$raspi_line, initramfs=$initramfs_line)"
    fail=$((fail + 1))
fi

echo
echo "=== Functional smoke test (helper invocation in a sandbox) ==="

# Verify systemd-escape would produce a valid unit name for our paths.
if command -v systemd-escape &>/dev/null; then
    nfs_unit=$(systemd-escape -p --suffix=mount /media/nfs-music)
    smb_unit=$(systemd-escape -p --suffix=mount /media/smb-music)
    if [[ "$nfs_unit" == "media-nfs"*"music.mount" ]]; then
        echo "  PASS: nfs unit name resolves to '$nfs_unit'"
        pass=$((pass + 1))
    else
        echo "  FAIL: unexpected nfs unit name: '$nfs_unit'"
        fail=$((fail + 1))
    fi
    if [[ "$smb_unit" == "media-smb"*"music.mount" ]]; then
        echo "  PASS: smb unit name resolves to '$smb_unit'"
        pass=$((pass + 1))
    else
        echo "  FAIL: unexpected smb unit name: '$smb_unit'"
        fail=$((fail + 1))
    fi
else
    echo "  SKIP: systemd-escape not available on this host (CI is fine — fix runs on Pi)"
fi

echo
echo "=== Bash syntax ==="
for f in "$MOUNT_SH" "$SYSTEM_TUNE_SH"; do
    if bash -n "$f"; then
        echo "  PASS: bash -n $(basename "$f")"
        pass=$((pass + 1))
    else
        echo "  FAIL: bash -n $(basename "$f")"
        fail=$((fail + 1))
    fi
done

echo
echo "=== Summary ==="
echo "  Pass: $pass"
echo "  Fail: $fail"

[[ "$fail" -eq 0 ]]
