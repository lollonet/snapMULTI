#!/usr/bin/env bash
# Sourced as a data library; `set -euo pipefail` intentionally omitted.
# shellcheck disable=SC2034
# (every STAGING_* array below is referenced by sourced consumers
# — tests/test_staging_manifest.sh today, prepare-sd.sh in a follow-up
# PR. shellcheck cannot follow the cross-file usage so it would warn
# on each array; the disable is global because every array is in the
# same situation.)
#
# staging-manifest.sh — SSOT for files staged into the SD bundle by
# scripts/prepare-sd.sh's copy_server_files / copy_client_files.
#
# Why this exists (v0.8 hardening track, PR4):
#   Several past bugs came from `prepare-sd.sh` copying a file that
#   firstboot then expected, but the source path had moved or never
#   landed in the repo at the right place:
#     - smoke/ directory shipped to /opt/snapmulti but not to
#       /opt/snapclient (v0.7.1 — fixed in PR #319)
#     - initramfs-hooks/ not in the client copy loop (snapdigi
#       2026-06-01 — fixed in PR #571)
#     - tidal/ scripts dir copy omitted on initial v0.7 cut
#
# This manifest is the declarative source of "what is supposed to
# ship". The companion test (tests/test_staging_manifest.sh) asserts:
#   1. Every REQUIRED entry exists in the source tree (so prepare-sd.sh
#      cannot silently miss it)
#   2. Every `cp `/`cp -r ` source path in copy_server_files /
#      copy_client_files corresponds to a manifest entry (so a new
#      copy line cannot land without being declared)
#   3. Every manifest entry is referenced by at least one cp/cp -r in
#      the matching copy_* function (so an entry cannot drift to dead
#      data)
#
# This PR is pure-additive: prepare-sd.sh is NOT refactored to read
# from the manifest. The audit's PR5 will do that. The value here is
# the contract — the tests catch drift today, before the refactor.
#
# Path conventions:
#   - All paths are RELATIVE to the repository root (PROJECT_DIR).
#   - Required = "must exist in source tree at SD-prep time, prepare-sd.sh
#     would fail or produce an unusable bundle without it"
#   - Optional = "absent file is silently skipped by `cp ... 2>/dev/null
#     || true` or `[[ -f ... ]] &&`"

# ─── Server bundle ─────────────────────────────────────────────────
# copy_server_files() target: $DEST/server/
STAGING_SERVER_REQUIRED=(
    "scripts/deploy.sh"
    "docker-compose.yml"
    "config"
)
STAGING_SERVER_OPTIONAL=(
    "scripts/boot-tune.sh"
    "scripts/status.sh"
    "scripts/device-smoke.sh"
    "scripts/diagnostic.sh"
    "scripts/smoke"
    "scripts/docker-driver-reconcile.sh"
    "scripts/tidal"
    "client/common/scripts/ro-mode.sh"
    "docker"
    ".env.example"
    "mpd/data/mpd.db"
)

# ─── Client bundle ─────────────────────────────────────────────────
# copy_client_files() target: $DEST/client/
STAGING_CLIENT_REQUIRED=(
    "client/install/snapclient.conf"
    "client/common/scripts/setup.sh"
    "client/common/docker-compose.yml"
)
STAGING_CLIENT_OPTIONAL=(
    "client/common/.env.example"
    "client/common/audio-hats"
    "client/common/docker"
    "client/common/public"
    "client/common/scripts/setup-zero2w.sh"
    "client/common/scripts/audio-hat-detect.sh"
    "client/common/scripts/ro-mode.sh"
    "client/common/scripts/discover-server.sh"
    "client/common/scripts/display.sh"
    "client/common/scripts/display-detect.sh"
    "client/common/systemd"
    "scripts/boot-tune.sh"
    "scripts/docker-driver-reconcile.sh"
    "scripts/device-smoke.sh"
    "scripts/diagnostic.sh"
    "scripts/smoke"
    "scripts/common/initramfs-hooks"
)

# Shared modules copied into both /opt/snapmulti/scripts/common/ AND
# /opt/snapclient/scripts/common/ under `both` mode (see the note in
# copy_client_files about the intentional duplication under DEC-003
# reflash-first).
STAGING_COMMON_SHARED_MODULES=(
    "scripts/common/install-deps.sh"
    "scripts/common/install-docker.sh"
    "scripts/common/system-tune.sh"
    "scripts/common/overlayroot-lifecycle.sh"
    "scripts/common/unified-log.sh"
    "scripts/common/logging.sh"
    "scripts/common/sanitize.sh"
    "scripts/common/systemd-snippets.sh"
)

# ─── Top-level bundle (always copied, not per-profile) ─────────────
STAGING_TOPLEVEL_REQUIRED=(
    "scripts/firstboot.sh"
    "scripts/common"
)
STAGING_TOPLEVEL_OPTIONAL=(
    "release-manifest.json"
)
