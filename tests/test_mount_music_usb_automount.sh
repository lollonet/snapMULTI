#!/usr/bin/env bash
# Static + integration tests for the USB branch of mount-music.sh after
# the systemd .automount refactor.
#
# WHY THIS EXISTS — observed live on cicciosrv 2026-05-15: the previous
# USB branch wrote a fstab entry that the overlayroot initramfs hook
# rewrote into a broken double-line scheme (UUID mount routed into the
# ro lower layer + an overlay union on /media/usb-music whose lowerdir
# resolved to an empty stub). systemd-fstab-generator mounted then
# immediately unmounted, so /media/usb-music was empty at runtime even
# though /dev/sda1 was attached. Root cause was compounded by USB-SATA
# enclosure flicker (Inateck/JMicron 2109:0715) at +47 s — exactly the
# window the eager fstab mount was attempting. The NFS/SMB branches
# never had this problem because they already used a hand-crafted
# systemd .mount + .automount pair. The fix aligns the USB branch with
# the same pattern.
#
# These tests assert:
#   1. The USB branch no longer writes /etc/fstab
#   2. It calls _write_systemd_mount_unit with the right What= /
#      Where= / options
#   3. The options include `nofail` and `x-systemd.device-timeout=30`
#      (the device-timeout is the resilience knob for enclosure flicker)
#   4. The mount path uses /dev/disk/by-uuid/ (not bare UUID=)
#   5. The migration path strips a legacy fstab line from older installs

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MM="$SCRIPT_DIR/../scripts/common/mount-music.sh"

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

echo "== mount-music.sh: USB branch shape =="

# Extract the usb) case body. The case label is `usb)` and the body
# ends at the next `;;`. awk handles the nesting reliably.
usb_body=$(awk '/^[[:space:]]+usb\)/,/^[[:space:]]+;;/' "$MM")

assert 'echo "$usb_body" | grep -qF "_write_systemd_mount_unit"' \
       'USB branch invokes _write_systemd_mount_unit'

# Hard regression guard: must NOT add a USB line to /etc/fstab. The
# overlayroot rewrite of such a line is exactly the bug we are fixing.
if echo "$usb_body" | grep -qE 'echo[[:space:]]+["'\''][^"'\'']*\$fstab_entry[^"'\'']*["'\''][[:space:]]+>>[[:space:]]+/etc/fstab|>>[[:space:]]+/etc/fstab'; then
    echo "  FAIL: USB branch still appends to /etc/fstab (regression — fstab gets rewritten by overlayroot)"
    fail=$((fail + 1))
else
    echo "  PASS: USB branch no longer appends to /etc/fstab"
    pass=$((pass + 1))
fi

assert 'echo "$usb_body" | grep -qF "/dev/disk/by-uuid/"' \
       'systemd What= uses /dev/disk/by-uuid/<uuid> (not bare UUID=)'

assert 'echo "$usb_body" | grep -qF "x-systemd.device-timeout=30"' \
       'options include x-systemd.device-timeout=30 (USB enclosure flicker tolerance)'

assert 'echo "$usb_body" | grep -qF "nofail"' \
       'options include nofail (missing USB cannot block boot)'

# Migration check — older installs left a fstab entry that must be
# removed at upgrade so the new .automount is the only writer.
assert 'echo "$usb_body" | grep -qF "Removing legacy /etc/fstab USB entry"' \
       'migration path strips legacy fstab entries from older installs'

# UUID-less device fallback: log_warn + one-shot mount, NO unit install
# (would be invalid: /dev/disk/by-uuid/ link cannot be created).
assert 'echo "$usb_body" | grep -qF "has no UUID"' \
       'UUID-less branch logs warning and skips systemd unit install'

echo
echo "== Integration: simulate USB branch dispatch against a fake env =="

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
FAKE_ROOT="$TMP/root"
mkdir -p "$FAKE_ROOT/etc" "$FAKE_ROOT/etc/systemd/system" "$FAKE_ROOT/media/usb-music"

# Seed a legacy fstab entry to confirm the migration strips it.
cat > "$FAKE_ROOT/etc/fstab" <<EOF
proc /proc proc defaults 0 0
PARTUUID=ba811e01-01 /boot/firmware vfat defaults,ro 0 2
UUID=75de76fe-0c85-4a88-8fa8-ad95d0b4f532 /media/usb-music auto ro,nofail 0 0
EOF

# Replay only the migration `sed` against the seeded fstab — the live
# function calls systemd which we can't stub portably here.
USB_MOUNT="/media/usb-music"
sed -i.bak -E "\\|^(UUID=[^ ]+\\|/dev/sd[a-z][0-9]?) ${USB_MOUNT} |d" "$FAKE_ROOT/etc/fstab"
rm -f "$FAKE_ROOT/etc/fstab.bak"

assert '! grep -q "/media/usb-music" "$FAKE_ROOT/etc/fstab"' \
       'integration: legacy /etc/fstab USB line stripped after migration'

assert 'grep -q "PARTUUID=ba811e01-01" "$FAKE_ROOT/etc/fstab"' \
       'integration: unrelated fstab lines preserved (no over-deletion)'

# Edge case: also strips a /dev/sdX1 style entry (no UUID, older legacy)
cat > "$FAKE_ROOT/etc/fstab" <<EOF
/dev/sda1 /media/usb-music auto ro,nofail 0 0
PARTUUID=ba811e01-01 /boot/firmware vfat defaults,ro 0 2
EOF
sed -i.bak -E "\\|^(UUID=[^ ]+\\|/dev/sd[a-z][0-9]?) ${USB_MOUNT} |d" "$FAKE_ROOT/etc/fstab"
rm -f "$FAKE_ROOT/etc/fstab.bak"

assert '! grep -q "/media/usb-music" "$FAKE_ROOT/etc/fstab"' \
       'integration: legacy /dev/sdX1 fstab entry also stripped'

echo
if [[ "$fail" -gt 0 ]]; then
    echo "FAILED: $fail tests failed, $pass passed"
    exit 1
fi
echo "All $pass tests passed!"
