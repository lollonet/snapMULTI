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
# Verified live on pi-server post-PR-#319 reflash. Install module
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

# Inside copy_server_files() we should copy PROJECT_DIR/docker
# *idempotently* — `cp -r src/. dst/` copies contents (no nesting).
copy_block=$(awk '/^copy_server_files\(\)/,/^\}/' "$PREP")

assert 'echo "$copy_block" | grep -qE "cp -r \"\\\$PROJECT_DIR/docker/\\.\" \"\\\$dest/docker/\""' \
       'copy_server_files uses idempotent `cp -r $PROJECT_DIR/docker/. $dest/docker/`'

assert 'echo "$copy_block" | grep -qE "\\[\\[ -d \"\\\$PROJECT_DIR/docker\" \\]\\]"' \
       'docker copy is guarded on the source directory existing'

# Negative: must NOT use the bare `cp -r src dst/` form which nests
# `dst/docker/docker/` on re-prep of the same SD card.
assert '! echo "$copy_block" | grep -qE "cp -r \"\\\$PROJECT_DIR/docker\" \"\\\$dest/\""' \
       'copy_server_files does NOT use the non-idempotent `cp -r src dst/` form'

echo
echo "=== prepare-sd.sh — copy scripts/tidal/ to boot partition ==="

assert 'echo "$copy_block" | grep -qE "cp -r \"\\\$SCRIPT_DIR/tidal/\\.\" \"\\\$dest/scripts/tidal/\""' \
       'copy_server_files copies scripts/tidal/ contents idempotently'

assert 'echo "$copy_block" | grep -qE "\\[\\[ -d \"\\\$SCRIPT_DIR/tidal\" \\]\\]"' \
       'tidal script copy is guarded on the source directory existing'

echo
echo "=== firstboot.sh — copy docker/ from boot to /opt/snapmulti ==="

# Inside the server-copy block we should copy SNAP_BOOT/server/docker.
# No `head -N` here: awk's range terminates at the first matching `^fi$`
# already, and on Ubuntu mawk an early `head` close + `pipefail` would
# SIGPIPE the substitution and silently kill the test (CI-only failure
# mode, not reproducible on macOS gawk).
fb_block=$(awk '/INSTALL_TYPE.*server.*both/,/^fi$/' "$FIRSTBOOT")

assert 'echo "$fb_block" | grep -qE "cp -rT \"\\\$SNAP_BOOT/server/docker\" \"\\\$SERVER_DIR/docker\""' \
       'firstboot copies docker/ to /opt/snapmulti via cp -rT (idempotent)'

assert 'echo "$fb_block" | grep -qE "\\[\\[ -d \"\\\$SNAP_BOOT/server/docker\" \\]\\]"' \
       'firstboot copy is guarded on the source directory existing'

# The cp -rT form (not bare `cp -r`) prevents the
# /opt/snapmulti/docker/docker/ nesting on partial-install retry.
assert '! echo "$fb_block" | grep -qE "cp -r \"\\\$SNAP_BOOT/server/docker\" \"\\\$SERVER_DIR/\""' \
       'cp -r without -T is NOT used (would nest on retry)'

echo
echo "=== firstboot.sh — copy scripts/tidal/ from boot to /opt/snapmulti ==="

assert 'echo "$fb_block" | grep -qE "cp -r \"\\\$SNAP_BOOT/server/scripts/tidal/\\.\" \"\\\$SERVER_DIR/scripts/tidal/\""' \
       'firstboot copies server/scripts/tidal/ to /opt/snapmulti/scripts/tidal/'

assert 'echo "$fb_block" | grep -qE "\\[\\[ -d \"\\\$SNAP_BOOT/server/scripts/tidal\" \\]\\]"' \
       'firstboot tidal copy is guarded on the source directory existing'

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
