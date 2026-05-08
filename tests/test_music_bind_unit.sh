#!/usr/bin/env bash
# Verify the snapmulti-music-bind workaround:
#   - unit + script files exist in scripts/common/
#   - unit declares the right ordering vs docker / snapserver
#   - firstboot installs them only for server/both modes with
#     MUSIC_SOURCE in {nfs,smb}
#   - script bind-mount logic is idempotent (mountpoint -q guard)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# COMMON_DIR and FIRSTBOOT are referenced inside the eval'd `assert` strings
# below; shellcheck cannot see usage through eval, so silence SC2034.
# shellcheck disable=SC2034
COMMON_DIR="$SCRIPT_DIR/../scripts/common"
# shellcheck disable=SC2034
FIRSTBOOT="$SCRIPT_DIR/../scripts/firstboot.sh"

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

echo "=== snapmulti-music-bind ==="

# Files exist
assert '[[ -f "$COMMON_DIR/snapmulti-music-bind.sh" ]]' \
       "helper script present"
assert '[[ -f "$COMMON_DIR/snapmulti-music-bind.service" ]]' \
       "systemd unit present"

# Helper script: idempotent guard + correct mode
assert '[[ -x "$COMMON_DIR/snapmulti-music-bind.sh" ]]' \
       "helper script is executable"
assert 'grep -q "mountpoint -q" "$COMMON_DIR/snapmulti-music-bind.sh"' \
       "helper script guards on mountpoint -q (idempotent)"
assert 'grep -q "/media/root-ro/media/nfs-music" "$COMMON_DIR/snapmulti-music-bind.sh"' \
       "helper handles NFS path"
assert 'grep -q "/media/root-ro/media/smb-music" "$COMMON_DIR/snapmulti-music-bind.sh"' \
       "helper handles SMB path"

# Unit ordering: must run BEFORE docker.service so MPD bind-mount sees content
assert 'grep -qE "^Before=.*docker.service" "$COMMON_DIR/snapmulti-music-bind.service"' \
       "unit declares Before=docker.service"
assert 'grep -qE "^Before=.*snapmulti-server.service" "$COMMON_DIR/snapmulti-music-bind.service"' \
       "unit declares Before=snapmulti-server.service"
assert 'grep -qE "^After=remote-fs.target" "$COMMON_DIR/snapmulti-music-bind.service"' \
       "unit declares After=remote-fs.target"
assert 'grep -qE "^ConditionPathIsMountPoint=/media/root-ro" "$COMMON_DIR/snapmulti-music-bind.service"' \
       "unit no-ops when overlayroot inactive"
assert 'grep -qE "^Type=oneshot" "$COMMON_DIR/snapmulti-music-bind.service"' \
       "unit is oneshot"
assert 'grep -qE "^RemainAfterExit=yes" "$COMMON_DIR/snapmulti-music-bind.service"' \
       "unit RemainAfterExit=yes (so Before= ordering survives)"

# firstboot installs them only for server / both with NFS / SMB
assert 'grep -q "snapmulti-music-bind" "$FIRSTBOOT"' \
       "firstboot.sh references the music-bind unit"
assert 'grep -A6 "snapmulti-music-bind" "$FIRSTBOOT" | grep -q "MUSIC_SOURCE"' \
       "firstboot gates install on MUSIC_SOURCE"

echo
if (( fail > 0 )); then
    echo "FAILED: $fail / $((pass + fail))"
    exit 1
fi
echo "All $pass tests passed!"
