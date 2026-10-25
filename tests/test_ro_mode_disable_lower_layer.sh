#!/usr/bin/env bash
# `ro-mode disable` must clear overlayroot.local.conf from the LOWER root.
#
# overlayroot reads <lower>/etc/overlayroot.local.conf at boot even when
# cmdline.txt carries no overlayroot= token, so a copy left on the lower
# layer keeps tmpfs mode on after the reboot. Under a live overlay that
# layer (/media/root-ro) is mounted ro, so the removal needs a temporary
# remount,rw — a bare `rm` fails with EROFS and the old code ignored it.
#
# clear_lower_overlayroot is exercised against a sandbox lower root with
# mount/findmnt stubbed on PATH (no root, no real mounts).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LIB="$REPO_ROOT/scripts/common/overlayroot-lifecycle.sh"
RO_MODE="$REPO_ROOT/client/common/scripts/ro-mode.sh"

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

SBX=$(mktemp -d)
trap 'rm -rf "${SBX:?}"' EXIT
mkdir -p "$SBX/bin"

# findmnt prints $SBX/opts; mount logs its args and exits $SBX/mount_rc_<op>.
cat > "$SBX/bin/findmnt" <<EOF
#!/usr/bin/env bash
cat "$SBX/opts" 2>/dev/null
EOF
cat > "$SBX/bin/mount" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$SBX/mount.log"
case "\$2" in
    remount,rw) exit "\$(cat "$SBX/mount_rc_rw" 2>/dev/null || echo 0)" ;;
    remount,ro) exit "\$(cat "$SBX/mount_rc_ro" 2>/dev/null || echo 0)" ;;
esac
EOF
chmod +x "$SBX/bin/findmnt" "$SBX/bin/mount"

# Fresh lower root holding both activation files; $1 = mount options.
setup_lower() {
    rm -rf "$SBX/lower" "$SBX/mount.log" "$SBX/mount_rc_rw" "$SBX/mount_rc_ro"
    mkdir -p "$SBX/lower/etc/systemd/system.conf.d"
    printf 'overlayroot="tmpfs:recurse=0"\n' > "$SBX/lower/etc/overlayroot.local.conf"
    printf '[Manager]\n' > "$SBX/lower/etc/systemd/system.conf.d/overlayfs-workaround.conf"
    printf '%s\n' "$1" > "$SBX/opts"
}

run_clear() {
    PATH="$SBX/bin:$PATH" bash -c 'source "$1"; clear_lower_overlayroot "$2"' _ "$LIB" "$SBX/lower" >/dev/null 2>&1
}

conf_gone()       { [[ ! -e "$SBX/lower/etc/overlayroot.local.conf" ]]; }
workaround_gone() { [[ ! -e "$SBX/lower/etc/systemd/system.conf.d/overlayfs-workaround.conf" ]]; }
logged()          { grep -qx -- "$1" "$SBX/mount.log" 2>/dev/null; }
no_mounts()       { [[ ! -s "$SBX/mount.log" ]]; }
not()             { ! "$@"; }
rw_before_ro()    { [[ "$(head -n1 "$SBX/mount.log" 2>/dev/null)" == "-o remount,rw $SBX/lower" ]]; }

echo "## lower root mounted ro (live overlay)"
setup_lower "ro,relatime"
check "returns 0" run_clear
check "remounts the lower root rw first" rw_before_ro
check "removes overlayroot.local.conf" conf_gone
check "removes the systemd workaround drop-in" workaround_gone
check "puts the lower root back to ro" logged "-o remount,ro $SBX/lower"

echo "## remount ro reports busy (expected while the overlay is live)"
setup_lower "ro,relatime"
echo 32 > "$SBX/mount_rc_ro"
check "still returns 0" run_clear
check "file removed" conf_gone

echo "## remount rw refused"
setup_lower "ro,relatime"
echo 32 > "$SBX/mount_rc_rw"
check "returns 1" not run_clear
check "file left in place" bash -c '[[ -e "$1" ]]' _ "$SBX/lower/etc/overlayroot.local.conf"

echo "## lower root already rw"
setup_lower "rw,relatime"
check "returns 0" run_clear
check "no remount" no_mounts
check "file removed" conf_gone

echo "## file cannot be removed (EISDIR stands in for any rm failure)"
setup_lower "rw,relatime"
rm -f "$SBX/lower/etc/overlayroot.local.conf"
mkdir "$SBX/lower/etc/overlayroot.local.conf"
check "returns 1" not run_clear

echo "## no overlay (lower root has no /etc)"
rm -rf "$SBX/lower" "$SBX/mount.log"; mkdir -p "$SBX/lower"
check "returns 0" run_clear
check "no remount" no_mounts

echo "## ro-mode.sh disable wiring"
disable_block=$(awk '/^    disable\)/{f=1} f&&/^        ;;/{exit} f' "$RO_MODE")
check "calls clear_lower_overlayroot /media/root-ro" \
    grep -q 'clear_lower_overlayroot /media/root-ro' <<< "$disable_block"
check "exits non-zero when it fails" \
    grep -qE 'if ! clear_lower_overlayroot' <<< "$disable_block"
check "no bare rm on the lower root left" \
    bash -c '! grep -q "rm -f /media/root-ro" <<< "$1"' _ "$disable_block"

echo
echo "## Summary"
echo "  Passed: $pass"
echo "  Failed: $fail"
[[ $fail -eq 0 ]]
