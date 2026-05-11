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
# survive. No fstab migration code: snapMULTI uses reflash as its
# primary update strategy (DEC-003), so there is never a legacy fstab
# entry to clean up. The unit file in /etc/systemd/system/ is
# overwritten idempotently on retry.
#
# Also tests the defensive companion in system-tune.sh:
#   - The extra `update-initramfs -u -k all` after `do_overlayfs 0` was
#     REMOVED — verified 2026-05-10 to cause a self-realising
#     "first-boot needs manual reboot" WARN on both pi-server and
#     pi-display (mkinitramfs aborts because raspi-config has already
#     activated the overlay). raspi-config's internal `-c -k all` does
#     the rebuild correctly. Regression guard asserts the extra rebuild
#     does NOT come back.
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

assert 'grep -qE "systemctl enable.*automount_name" "$MOUNT_SH"' \
       'helper enables the .automount companion (lazy mount, NOT the .mount itself)'

assert 'grep -qE "systemd-escape -p --suffix=automount" "$MOUNT_SH"' \
       'helper computes a sibling .automount unit name'

assert 'grep -qE "\\[Automount\\]" "$MOUNT_SH"' \
       'helper writes an [Automount] section to the companion unit'

# CRITICAL: the .automount companion must NOT carry network ordering.
# An `After=network-online.target` / `Wants=network-online.target`
# inside the .automount block creates a systemd ordering cycle
# (sysinit → local-fs → automount → network-online → network →
# sysinit). systemd resolves the cycle by DELETING local-fs.target
# and sockets.target — first post-overlayroot boot comes up degraded,
# user observes "device without network", manual power-cycle ensues.
# Verified live 2026-05-10 on pi-server + pi-display.
#
# This regression guard parses the .automount heredoc only (between
# `cat > "$automount_path" << EOF` and the closing `EOF`) and asserts
# no executable line in that block carries `network-online.target`.
# The .mount heredoc above legitimately has the directive.
automount_block=$(awk '
    /cat > "\$automount_path" << EOF/ {in_block=1; next}
    in_block && /^EOF$/ {in_block=0; next}
    in_block {print}
' "$MOUNT_SH")

if echo "$automount_block" | grep -v "^[[:space:]]*#" | grep -qE "network-online\\.target|nss-lookup\\.target"; then
    echo "  FAIL: .automount unit carries network-online.target dependency (creates ordering cycle)"
    fail=$((fail + 1))
else
    echo "  PASS: .automount unit has no network-online.target dependency (avoids ordering cycle)"
    pass=$((pass + 1))
fi

# Idempotency: helper must disable a pre-existing .mount enable before
# enabling the .automount, so devices that ran earlier versions of
# mount-music.sh (with systemctl enable on the .mount) end up in a
# clean state — only .automount in multi-user.target.wants/.
assert 'grep -qE "systemctl disable .\\\$mount_name" "$MOUNT_SH"' \
       'helper disables a pre-existing .mount enable before enabling .automount (idempotent)'

# With lazy automount the .mount fires on first access from inside MPD,
# well after snapmulti-server.service is already running. A boot-time
# Before= ordering directive in the .mount unit would be dead and
# mislead readers about the topology.
assert '! grep -qE "^Before=snapmulti-server\\.service snapclient\\.service" "$MOUNT_SH"' \
       '.mount unit no longer carries a dead Before= directive (lazy automount makes it irrelevant)'

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

# nofail must be in the options passed to the helper. The helper itself
# never writes /etc/fstab (single authority — see assertion below), so
# this is defence in depth: if a future contributor adds a manual
# fstab fallback, nofail will at least be preserved.
assert 'echo "$nfs_block" | grep -qE "nofail"' \
       'nfs options include nofail'

assert 'echo "$smb_block" | grep -qE "nofail"' \
       'smb options include nofail'

# Single authority: the helper itself MUST NOT write /etc/fstab as a
# fallback. The earlier fallback (when systemd-escape was unavailable)
# defeated PR #311 — overlayroot rewrites fstab and strips `nofail`,
# routing a transient NFS miss into emergency.target. systemd-escape
# is part of systemd itself (always present on Pi OS Bookworm/Trixie),
# so the fallback was dead code. Helper now hard-fails instead.
helper_block=$(awk '/^_write_systemd_mount_unit\(\)/,/^}/' "$MOUNT_SH")

assert '! echo "$helper_block" | grep -qE "echo .* >> /etc/fstab"' \
       'helper does NOT write /etc/fstab as a fallback (single authority)'

assert 'echo "$helper_block" | grep -qE "log_error.*systemd-escape unavailable"' \
       'helper hard-fails with diagnostic when systemd-escape is missing'

assert 'echo "$helper_block" | grep -qE "return 1"' \
       'helper returns non-zero on missing systemd-escape (no silent fallback)'

# snapMULTI uses reflash as primary update strategy (DEC-003), so there is
# never a "legacy fstab line" to migrate. The unit file in
# /etc/systemd/system/ is overwritten idempotently on retry.

echo
echo "=== deploy.sh — RequiresMountsFor must NOT include music for network sources ==="

# After the lazy-automount fix, snapmulti-server.service no longer has a
# hard dependency on the network music share. snapserver / Spotify /
# AirPlay / Snapcast must start regardless of whether the NAS is up.
DEPLOY_SH="$SCRIPT_DIR/../scripts/deploy.sh"

assert '! grep -qE "music_mount_clause=. \\\$music_path_from_env" "$DEPLOY_SH"' \
       'deploy.sh does NOT add MUSIC_PATH to RequiresMountsFor for network sources'

assert 'grep -qE "using systemd \\.automount" "$DEPLOY_SH"' \
       'deploy.sh logs that lazy automount is used for network sources'

assert 'grep -qE "RequiresMountsFor=\\\${PROJECT_ROOT} \\\${PROJECT_ROOT}/audio\\\${music_mount_clause}" "$DEPLOY_SH"' \
       'RequiresMountsFor template still includes only project_root + audio (clause stays empty for network)'

echo
echo "=== system-tune.sh — defensive overlayroot setup ==="

# Verified 2026-05-10 on pi-server + pi-display: an explicit
# `update-initramfs -u -k all` after `do_overlayfs 0` calls into
# mkinitramfs which can no longer determine the device for `/`
# (raspi-config has already activated the overlay) and aborts. The
# fail was silent BUT the WARN message it emitted was self-realising
# — both devices required a manual power-cycle on first boot. The
# correct path is to trust raspi-config's internal `-c -k all` and
# NOT add an extra `-u` after it. This assertion enforces that the
# extra rebuild does not come back as a regression.
# Regression guard: any UNCOMMENTED line invoking `update-initramfs -u -k
# all` reintroduces the failure mode. Filter shell comments first, then
# fixed-string match on the call — catches the previous `if update-initramfs
# ...; then` form, a bare call, a call inside a subshell or variable
# assignment, etc. The current file legitimately mentions the string in a
# NOTE comment explaining why the call was removed; that is filtered out.
assert '! grep -v "^[[:space:]]*#" "$SYSTEM_TUNE_SH" | grep -qF "update-initramfs -u -k all"' \
       'setup_readonly_fs does NOT call extra update-initramfs after raspi-config (regression guard)'

assert 'grep -qE "console=tty1" "$SYSTEM_TUNE_SH"' \
       'setup_readonly_fs sanity-checks cmdline.txt for console=tty1'

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
