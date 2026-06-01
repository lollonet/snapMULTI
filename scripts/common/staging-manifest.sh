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
#   3. Every REQUIRED manifest entry is referenced by at least one cp/
#      cp -r in the matching copy_* function (so a required entry cannot
#      drift to dead data). OPTIONAL entries are NOT enforced — they
#      may legitimately be present in the manifest without a current
#      cp (e.g. forthcoming additions, or files only relevant on certain
#      profiles where the cp is gated upstream).
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
#
# v0.8 PR6: parallel STAGING_*_DESTS arrays carry the destination
# subdirectory under the bundle root (server/ or client/) for each
# manifest entry. Empty string = bundle root. `stage_manifest_entry`
# in `prepare-sd.sh` reads both arrays at the same index. The
# special-case copies that don't fit the manifest pattern
# (`mpd.db` MUSIC_SOURCE gate, `tidal/.` subdir copy, `docker/.`
# idempotent idiom, `initramfs-hooks/*` nullglob array) stay inline
# in `copy_*_files`.

# ─── Server bundle ─────────────────────────────────────────────────
# copy_server_files() target: $DEST/server/. The PARALLEL _DESTS arrays
# carry the subdirectory under server/ for each entry; empty string =
# server/ root. v0.8 PR6 wired prepare-sd.sh to use this contract.
STAGING_SERVER_REQUIRED=(
    "scripts/deploy.sh"
    "docker-compose.yml"
    "config"
)
STAGING_SERVER_REQUIRED_DESTS=(
    ""
    ""
    ""
)
STAGING_SERVER_OPTIONAL=(
    "scripts/boot-tune.sh"
    "scripts/status.sh"
    "scripts/device-smoke.sh"
    "scripts/diagnostic.sh"
    "scripts/smoke"
    "scripts/docker-driver-reconcile.sh"
    "client/common/scripts/ro-mode.sh"
    ".env.example"
)
STAGING_SERVER_OPTIONAL_DESTS=(
    ""
    ""
    ""
    ""
    ""
    ""
    ""
    ""
)
# Special-case entries (stay inline in copy_server_files because they
# have conditional logic the generic stage_manifest_entry can't model):
#   - scripts/tidal      → server/scripts/tidal/  (subdir copy idiom)
#   - docker             → server/docker/         (idempotent cp src/.)
#   - mpd/data/mpd.db    → server/mpd/data/       (MUSIC_SOURCE gated)
# These are NOT in the loop arrays above so the static manifest test
# doesn't mistake them for unhandled drift.
STAGING_SERVER_SPECIAL_INLINE=(
    "scripts/tidal"
    "docker"
    "mpd/data/mpd.db"
)

# ─── Client bundle ─────────────────────────────────────────────────
# copy_client_files() target: $DEST/client/. PARALLEL _DESTS arrays as
# above; non-empty dest = subdirectory under client/.
STAGING_CLIENT_REQUIRED=(
    "client/install/snapclient.conf"
    "client/common/scripts/setup.sh"
    "client/common/docker-compose.yml"
)
STAGING_CLIENT_REQUIRED_DESTS=(
    ""
    "scripts"
    ""
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
)
STAGING_CLIENT_OPTIONAL_DESTS=(
    ""
    ""
    ""
    ""
    "scripts"
    "scripts"
    "scripts"
    "scripts"
    "scripts"
    "scripts"
    ""
    "scripts"
    "scripts"
    "scripts"
    "scripts"
    "scripts"
)
# Special-case: scripts/common/initramfs-hooks/* is a runtime glob
# array `_hooks=("$SCRIPT_DIR/common/initramfs-hooks/"*)` with nullglob
# guard, NOT a generic cp. Stays inline in copy_client_files.
STAGING_CLIENT_SPECIAL_INLINE=(
    "scripts/common/initramfs-hooks"
)

# Shared modules copied into both /opt/snapmulti/scripts/common/ AND
# /opt/snapclient/scripts/common/ under `both` mode (see the note in
# copy_client_files about the intentional duplication under DEC-003
# reflash-first). Dest = client/scripts/common/ for the client bundle.
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
STAGING_COMMON_SHARED_MODULES_DEST="scripts/common"

# stage_manifest_entry SRC_REL BUNDLE_ROOT DEST_SUBDIR REQUIRED
#
#   SRC_REL      — path relative to PROJECT_DIR (the repo root)
#   BUNDLE_ROOT  — absolute dest dir for the bundle (e.g. $1/server)
#   DEST_SUBDIR  — subdirectory under BUNDLE_ROOT; empty string = root
#   REQUIRED     — "true" / "false"; required + missing = error + rc 1
#
# Returns 0 on success (or graceful skip), 1 if a REQUIRED source is
# missing. Directories are copied with the idempotent `cp -r src/. dst/`
# idiom so re-prep doesn't create nested copies. Caller is responsible
# for keeping the dest BUNDLE_ROOT created (mkdir -p) before calling
# the first time.
stage_manifest_entry() {
    local src_rel="$1" bundle_root="$2" dest_subdir="$3" required="$4"
    local src_abs="$PROJECT_DIR/$src_rel"
    local dest_dir="$bundle_root"
    [[ -n "$dest_subdir" ]] && dest_dir="$bundle_root/$dest_subdir"

    if [[ ! -e "$src_abs" ]]; then
        if [[ "$required" == "true" ]]; then
            echo "ERROR: required staging entry missing: $src_rel" >&2
            return 1
        fi
        return 0
    fi

    mkdir -p "$dest_dir"
    if [[ -d "$src_abs" ]]; then
        local base
        base="$(basename "$src_rel")"
        mkdir -p "$dest_dir/$base"
        cp -r "$src_abs/." "$dest_dir/$base/"
    else
        cp "$src_abs" "$dest_dir/"
    fi
}

# ─── Top-level bundle (always copied, not per-profile) ─────────────
STAGING_TOPLEVEL_REQUIRED=(
    "scripts/firstboot.sh"
    "scripts/common"
)
STAGING_TOPLEVEL_OPTIONAL=(
    "release-manifest.json"
)
