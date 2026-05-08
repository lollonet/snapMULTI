#!/usr/bin/env bash
# shellcheck disable=SC2016  # assert() conditions are eval'd, single quotes intentional.
#
# Static checks for the docker/ directory copy fix.
#
# The bug: PR #319 added a bind-mount for docker/metadata-service/
# metadata-service.py in docker-compose.yml, but neither prepare-sd.sh
# nor firstboot.sh copied the docker/ directory from PROJECT_ROOT to
# /boot/firmware/snapmulti/server/ and from there to /opt/snapmulti/.
# Result: at first `docker compose up -d`, Docker auto-created an empty
# directory at the bind source and the metadata container failed with:
#
#   not a directory: Are you trying to mount a directory onto a file
#   (or vice-versa)?
#
# Verified live on snapvideo post-PR-#319 reflash. Install module
# `deploy` exited 1 with this exact message.
#
# Fix: prepare-sd.sh's copy_server_files() now `cp -r` the docker/
# tree to the boot partition; firstboot.sh's server-copy block does
# the same from boot to /opt/snapmulti/.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PREP="$SCRIPT_DIR/../scripts/prepare-sd.sh"
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

echo "=== prepare-sd.sh — copy docker/ to boot partition ==="

# Inside copy_server_files() we should copy PROJECT_DIR/docker.
copy_block=$(awk '/^copy_server_files\(\)/,/^\}/' "$PREP")

assert 'echo "$copy_block" | grep -qE "cp -r \"\\\$PROJECT_DIR/docker\""' \
       'copy_server_files runs `cp -r $PROJECT_DIR/docker $dest/`'

assert 'echo "$copy_block" | grep -qE "\\[\\[ -d \"\\\$PROJECT_DIR/docker\" \\]\\]"' \
       'docker copy is guarded on the source directory existing'

echo
echo "=== firstboot.sh — copy docker/ from boot to /opt/snapmulti ==="

# Inside the server-copy block we should copy SNAP_BOOT/server/docker.
fb_block=$(awk '/INSTALL_TYPE.*server.*both/,/^fi$/' "$FIRSTBOOT" | head -60)

assert 'echo "$fb_block" | grep -qE "cp -rT \"\\\$SNAP_BOOT/server/docker\" \"\\\$SERVER_DIR/docker\""' \
       'firstboot copies docker/ to /opt/snapmulti via cp -rT (idempotent)'

assert 'echo "$fb_block" | grep -qE "\\[\\[ -d \"\\\$SNAP_BOOT/server/docker\" \\]\\]"' \
       'firstboot copy is guarded on the source directory existing'

# The cp -rT form (not bare `cp -r`) prevents the
# /opt/snapmulti/docker/docker/ nesting on partial-install retry.
assert '! echo "$fb_block" | grep -qE "cp -r \"\\\$SNAP_BOOT/server/docker\" \"\\\$SERVER_DIR/\""' \
       'cp -r without -T is NOT used (would nest on retry)'

echo
echo "=== Bash syntax ==="
for f in "$PREP" "$FIRSTBOOT"; do
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
