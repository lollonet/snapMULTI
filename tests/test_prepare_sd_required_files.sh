#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PREPARE_SD_SH="$SCRIPT_DIR/../scripts/prepare-sd.sh"
PREPARE_SD_PS1="$SCRIPT_DIR/../scripts/prepare-sd.ps1"

pass=0
fail=0

assert_contains() {
    local haystack="$1" needle="$2" desc="$3"
    if grep -qF "$needle" <<<"$haystack"; then
        echo "  PASS: $desc"
        pass=$((pass + 1))
    else
        echo "  FAIL: $desc (missing '$needle')"
        fail=$((fail + 1))
    fi
}

echo "Testing prepare-sd required file verification list..."

verify_block=$(sed -n '/for f in install.conf/,/^done/p' "$PREPARE_SD_SH")

assert_contains "$verify_block" "common/progress.sh" "progress.sh is required"
assert_contains "$verify_block" "common/logging.sh" "logging.sh is required"
assert_contains "$verify_block" "common/unified-log.sh" "unified-log.sh is required"
assert_contains "$verify_block" "common/install-docker.sh" "install-docker.sh is required"
assert_contains "$verify_block" "common/install-deps.sh" "install-deps.sh is required"
assert_contains "$verify_block" "common/setup-docker.sh" "setup-docker.sh is required"
assert_contains "$verify_block" "common/wait-network.sh" "wait-network.sh is required"
assert_contains "$verify_block" "common/mount-music.sh" "mount-music.sh is required"
# systemd-snippets.sh is sourced by deploy.sh (server) AND by setup.sh
# (client) to generate the snapmulti-server.service and snapclient.service
# unit files. If it is missing from the SD card, firstboot.sh's recursive
# copy from $SNAP_BOOT/common/ to /opt/{snapmulti,snapclient}/scripts/common/
# would silently drop it and the unit generators would emit incomplete
# service files. The verify gate must catch this before the operator
# inserts the card into the Pi.
assert_contains "$verify_block" "common/systemd-snippets.sh" "systemd-snippets.sh is required (server+client unit generator helper)"

# Client-mode verify list — client/scripts/common/ is a selective copy of
# the server's scripts/common/. systemd-snippets.sh must be in BOTH places
# because setup.sh runs from /opt/snapclient/scripts/ post-install and re-
# runs (live update path) would otherwise fail to find the helper.
client_verify_block=$(sed -n '/client\/scripts\/common\/install-deps.sh/,/^[[:space:]]*done$/p' "$PREPARE_SD_SH")
assert_contains "$client_verify_block" "client/scripts/common/systemd-snippets.sh" \
    "client-mode verify list includes systemd-snippets.sh"

# Bash selective copy loop (copy_client_files) must enumerate systemd-snippets.sh
# alongside the other shared modules — without it the file is not copied to
# the client install dir and the previous client verify assertion would have
# nothing to find.
#
# v0.8 PR6: copy_client_files now iterates STAGING_COMMON_SHARED_MODULES from
# scripts/common/staging-manifest.sh via stage_manifest_entry. Two-part check:
#   (a) systemd-snippets.sh is declared in STAGING_COMMON_SHARED_MODULES
#   (b) copy_client_files iterates that array via stage_manifest_entry
MANIFEST="$SCRIPT_DIR/../scripts/common/staging-manifest.sh"
manifest_block=$(awk '/^STAGING_COMMON_SHARED_MODULES=\(/,/^\)/' "$MANIFEST")
assert_contains "$manifest_block" "systemd-snippets.sh" \
    "staging-manifest.sh declares systemd-snippets.sh in STAGING_COMMON_SHARED_MODULES"
copy_block=$(sed -n '/^copy_client_files/,/^}/p' "$PREPARE_SD_SH")
assert_contains "$copy_block" 'STAGING_COMMON_SHARED_MODULES[@]' \
    "copy_client_files() iterates STAGING_COMMON_SHARED_MODULES via stage_manifest_entry"

server_verify_block=$(sed -n '/server\/docker-compose.yml/,/server\/ro-mode.sh/p' "$PREPARE_SD_SH")
assert_contains "$server_verify_block" "server/scripts/tidal/tidal-meta-bridge.sh" \
    "server verify list includes Tidal metadata bridge bind-mount source"

# PowerShell parity — Windows users go through prepare-sd.ps1, which has
# its own $requiredBase / client-required arrays and its own selective copy
# foreach. All three must include systemd-snippets.sh for parity.
if [[ -f "$PREPARE_SD_PS1" ]]; then
    ps1_required_base=$(sed -n '/\$requiredBase = @(/,/^[[:space:]]*)$/p' "$PREPARE_SD_PS1")
    assert_contains "$ps1_required_base" "common/systemd-snippets.sh" \
        "ps1 \$requiredBase includes common/systemd-snippets.sh"

    # NB: ps1 client-required array closes with `        )) {` not a bare `)`,
    # so the closing delimiter has to match the literal `)) {` — `^[[:space:]]*)$`
    # would never trip and sed would run to EOF, scoping the assert to the entire
    # tail of the file (assertion still passes because the string is present
    # above the close, but the range is unintentionally global).
    ps1_client_required=$(sed -n '/client\/scripts\/common\/install-deps.sh/,/)) {/p' "$PREPARE_SD_PS1")
    assert_contains "$ps1_client_required" "client/scripts/common/systemd-snippets.sh" \
        "ps1 client-required list includes systemd-snippets.sh"

    ps1_server_required=$(sed -n '/server\/docker-compose.yml/,/server\/config\/shairport-sync.conf/p' "$PREPARE_SD_PS1")
    assert_contains "$ps1_server_required" "server/scripts/tidal/tidal-meta-bridge.sh" \
        "ps1 server-required list includes Tidal metadata bridge bind-mount source"

    ps1_copy_foreach=$(sed -n '/foreach (\$shared in @(/,/))/p' "$PREPARE_SD_PS1")
    assert_contains "$ps1_copy_foreach" "systemd-snippets.sh" \
        "ps1 selective copy foreach includes systemd-snippets.sh"

    # v0.8 drift sync: ps1 requiredBase verify list must include the
    # v0.8 hardening track files that bash prepare-sd.sh sources at
    # lines 24, 30, 33 + the overlayroot SSOT module.
    for new_entry in cmdline-manager.sh install-profile.sh staging-manifest.sh overlayroot-lifecycle.sh; do
        assert_contains "$ps1_required_base" "common/$new_entry" \
            "ps1 \$requiredBase includes common/$new_entry"
    done

    # overlayroot-lifecycle.sh must also ship to client/ (sourced by
    # ro-mode.sh + system-tune.sh on client install).
    assert_contains "$ps1_client_required" "client/scripts/common/overlayroot-lifecycle.sh" \
        "ps1 client-required list includes overlayroot-lifecycle.sh"

    # Selective copy foreach must enumerate overlayroot-lifecycle.sh —
    # mirrors STAGING_COMMON_SHARED_MODULES in scripts/common/staging-manifest.sh.
    assert_contains "$ps1_copy_foreach" "overlayroot-lifecycle.sh" \
        "ps1 selective copy foreach includes overlayroot-lifecycle.sh"

    # initramfs-hooks/ must be explicitly copied to client/scripts/common/
    # (mirrors bash copy_client_files lines 596-610). The Copy-Item -Recurse
    # at the top level lands it under common/ root but not under client/.
    assert_contains "$(cat "$PREPARE_SD_PS1")" "common\\initramfs-hooks" \
        "ps1 copies initramfs-hooks/ to client/scripts/common/"
fi

echo ""
if [[ "$fail" -gt 0 ]]; then
    echo "FAILED: $fail tests failed, $pass passed"
    exit 1
fi
echo "All $pass tests passed!"
