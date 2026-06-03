#!/usr/bin/env bash
# diagnostic.sh — bundle snapMULTI runtime diagnostics into a single
# tarball suitable for attaching to a GitHub issue or pasting under
# `details` in a support thread.
#
# Output:
#   <out-dir>/snapmulti-diag-<reason>-<UTC-ts>.tar.gz   (default ~3-5 MB)
#
# Default <out-dir> is /boot/firmware/ — the boot partition is FAT32,
# persists across reboots, survives overlayroot (which keeps / read-only
# but never touches /boot/firmware), and is reachable from any PC by
# removing the SD card. That last property is critical: if the appliance
# fails to come up after install, the user can extract the bundle by
# moving the SD card to a laptop — no SSH needed.
#
# Contents:
#   smoke.json       device-smoke.sh --json --no-fail-on-warn (best-effort)
#   journal.log      journalctl --since "-1h" -u snapmulti-* -u snapclient* -u docker
#   docker.log       docker compose -f $compose logs --tail=200 --no-color
#   dmesg.log        dmesg | tail -300
#   modules.txt      lsmod | grep snd/bcm/fuse
#   hw.txt           /proc/cmdline, /proc/cpuinfo, /etc/asound.conf,
#                    vcgencmd get_throttled, measure_temp
#   install.conf     install.conf copy with credentials scrubbed
#   meta.txt         hostname, model, snapMULTI version, run reason
#
# Anonymisation: an `anonymise` filter pass scrubs IPv4 addresses (except
# loopback), MAC addresses, WiFi SSIDs from wpa_supplicant traces, and
# credential lines from any captured config (SMB_PASS=, SMB_USER=,
# *_TOKEN=, *_SECRET=, *_PASSWORD=). Hostname is left alone — most
# install issues are device-specific and the operator references their
# host by name in the resulting issue. If the user wants stronger
# anonymisation they can `tar tzf` the bundle and inspect/edit before
# sharing.

set -euo pipefail

# Source the env_get helper for the release-identity .env reads in the
# meta.txt collector below. Guarded so a stripped/legacy diagnostic.sh
# (e.g. operator-extracted from an old SD) still runs without it.
_DIAG_SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "$_DIAG_SELF_DIR/common/env-reader.sh" ]]; then
    # shellcheck source=common/env-reader.sh
    source "$_DIAG_SELF_DIR/common/env-reader.sh"
fi
unset _DIAG_SELF_DIR

# ─── Args ────────────────────────────────────────────────────────────
# diagnostic.sh [--reason <tag>] [--out-dir <path>]
#
# --reason   tag embedded in filename (default: manual). Common tags:
#              install-failed, smoke-failure, manual, crash, container-loop
# --out-dir  where to drop the tarball (default: /boot/firmware/)
REASON="manual"
OUT_DIR="/boot/firmware"
COMPOSE_FILE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --reason)   REASON="$2"; shift 2 ;;
        --out-dir)  OUT_DIR="$2"; shift 2 ;;
        --compose)  COMPOSE_FILE="$2"; shift 2 ;;
        -h|--help)
            sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)
            echo "ERROR: unknown argument: $1" >&2
            exit 2
            ;;
    esac
done

# Resolve OUT_DIR: try to create the requested path, fall back to /boot
# then $TMPDIR. The boot partition is the right primary target — FAT32
# survives reboot and is reachable from a removed SD card — but on a
# host with no /boot/firmware (dev machine, container) we still want
# the bundle to land somewhere.
if ! mkdir -p "$OUT_DIR" 2>/dev/null || [[ ! -w "$OUT_DIR" ]]; then
    if [[ -d /boot && -w /boot ]]; then
        OUT_DIR="/boot"
    else
        OUT_DIR="${TMPDIR:-/tmp}"
    fi
fi

# ─── Source device-detect.sh ────────────────────────────────────────
# Single authority for hardware probes (device_model, is_pi_zero_2w).
# Diagnostic.sh ships in several locations alongside common/ (via
# prepare-sd.sh + deploy.sh/setup.sh). Try the canonical candidates;
# if none are reachable, device_model is left undefined and the
# meta.txt collector below falls back to `echo unknown` via its
# `|| echo unknown` clause. We deliberately do NOT define an inline
# /proc/device-tree/model fallback here — duplicating detection
# logic is exactly what scripts/common/device-detect.sh is meant
# to prevent (council ownership finding) and the anti-drift gate
# tests/test_no_inline_pi_zero_2w.sh enforces this rule.
_DIAG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
for _candidate in \
    "$_DIAG_DIR/common/device-detect.sh" \
    "$_DIAG_DIR/../common/device-detect.sh" \
    "/opt/snapmulti/scripts/common/device-detect.sh" \
    "/opt/snapclient/scripts/common/device-detect.sh" \
    "/boot/firmware/snapmulti/common/device-detect.sh"; do
    if [[ -f "$_candidate" ]]; then
        # shellcheck source=common/device-detect.sh
        source "$_candidate"
        break
    fi
done
unset _candidate _DIAG_DIR

TS=$(date -u +%Y%m%d-%H%M%SZ)
BUNDLE_NAME="snapmulti-diag-${REASON}-${TS}"
BUNDLE_PATH="$OUT_DIR/${BUNDLE_NAME}.tar.gz"

# Working dir on tmpfs so we don't dirty the overlay upper layer with
# intermediate files. /run is tmpfs on every Pi OS install.
WORK_DIR=$(mktemp -d /run/snapmulti-diag.XXXXXX 2>/dev/null \
    || mktemp -d "${TMPDIR:-/tmp}/snapmulti-diag.XXXXXX")
STAGE_DIR="$WORK_DIR/$BUNDLE_NAME"
mkdir -p "$STAGE_DIR"

# Cleanup on exit. Each collector uses `|| true` (or explicit `|| rc=$?`)
# so mid-collection errors don't abort the script under set -e and a
# partial bundle is still useful. The trap removes the tmpfs work dir on
# any exit path.
cleanup() { rm -rf "$WORK_DIR" 2>/dev/null || true; }
trap cleanup EXIT INT TERM

log() { echo "[diag] $*" >&2; }

# ─── Anonymisation filter ────────────────────────────────────────────
# Applied to text files via stdin. Patterns are deliberately conservative
# — we mask only what is risky to share publicly, not everything that
# looks identifying. The maintainer reads many of these bundles and
# wholesale anonymisation makes them useless.
#
# Patterns are split into one `-e` per match instead of using string
# alternation `(A|B|C)` inside `()` — that's GNU-ERE only; BSD sed
# rejects it. The target is Linux Pi OS (GNU sed) but keeping the
# regex portable makes the script testable on macOS too.
anonymise() {
    sed -E \
        -e 's|([Ss][Mm][Bb]_PASS[[:space:]]*=[[:space:]]*).*|\1[REDACTED]|g' \
        -e 's|([Ss][Mm][Bb]_USER[[:space:]]*=[[:space:]]*).*|\1[REDACTED]|g' \
        -e 's|([A-Za-z][A-Za-z0-9_]*_TOKEN[[:space:]]*=[[:space:]]*).*|\1[REDACTED]|g' \
        -e 's|([A-Za-z][A-Za-z0-9_]*_SECRET[[:space:]]*=[[:space:]]*).*|\1[REDACTED]|g' \
        -e 's|([A-Za-z][A-Za-z0-9_]*_PASSWORD[[:space:]]*=[[:space:]]*).*|\1[REDACTED]|g' \
        -e 's|([A-Za-z][A-Za-z0-9_]*_PASSPHRASE[[:space:]]*=[[:space:]]*).*|\1[REDACTED]|g' \
        -e 's|(ssid=")[^"]+(")|\1[SSID]\2|g' \
        -e 's|(psk=")[^"]+(")|\1[REDACTED]\2|g' \
        -e 's|([Bb]earer[[:space:]]+)[A-Za-z0-9._-]{20,}|\1[REDACTED]|g' \
        -e 's|([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}|xx:xx:xx:xx:xx:xx|g' \
        -e 's|192\.168\.[0-9]{1,3}\.[0-9]{1,3}|x.x.x.x|g' \
        -e 's|10\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}|x.x.x.x|g' \
        -e 's|172\.1[6-9]\.[0-9]{1,3}\.[0-9]{1,3}|x.x.x.x|g' \
        -e 's|172\.2[0-9]\.[0-9]{1,3}\.[0-9]{1,3}|x.x.x.x|g' \
        -e 's|172\.3[01]\.[0-9]{1,3}\.[0-9]{1,3}|x.x.x.x|g'
}

# ─── Collection ─────────────────────────────────────────────────────
log "Collecting snapMULTI diagnostics (reason=$REASON, out=$BUNDLE_PATH)"

# meta.txt — top-of-bundle context. Always present even when other
# collectors fail (e.g. apt running, dmesg restricted).
{
    echo "snapmulti-diag bundle"
    echo "generated_at_utc=$TS"
    echo "reason=$REASON"
    echo "hostname=$(hostname 2>/dev/null || echo unknown)"
    # Use device_model() from scripts/common/device-detect.sh — single
    # authority for /proc/device-tree/model reads (cached, error-tolerant).
    # The fallback definition above covers stripped-bundle scenarios.
    echo "model=$(device_model 2>/dev/null || echo unknown)"
    echo "kernel=$(uname -r 2>/dev/null || echo unknown)"
    echo "uptime=$(uptime -p 2>/dev/null || echo unknown)"
    echo "snapmulti_version=$(cat /opt/snapmulti/VERSION 2>/dev/null \
                               || cat /opt/snapclient/VERSION 2>/dev/null \
                               || echo unknown)"
    echo "install_type=$(grep -m1 '^INSTALL_TYPE=' /opt/snapmulti/install.conf 2>/dev/null \
                          || grep -m1 '^INSTALL_TYPE=' /opt/snapclient/install.conf 2>/dev/null \
                          || grep -m1 '^INSTALL_TYPE=' /boot/firmware/snapmulti/install.conf 2>/dev/null \
                          || grep -m1 '^INSTALL_TYPE=' /boot/snapmulti/install.conf 2>/dev/null \
                          || echo unknown)"
    # Release identity (manifest-aware). Reads SNAPMULTI_RELEASE /
    # SNAPMULTI_IMAGE_SET from the .env file that deploy.sh writes;
    # falls through to "unknown" so the diagnostic bundle has consistent
    # shape across all installs (legacy + new). Helper-based read with
    # strip=none preserves the raw verbatim value the legacy grep|cut
    # form produced; inline fallback (no env_get) keeps diagnostic.sh
    # usable on stripped/legacy bundles where env-reader.sh did not ship.
    if declare -F env_get >/dev/null 2>&1; then
        _diag_release=$(env_get SNAPMULTI_RELEASE /opt/snapmulti/.env  none)
        [[ -z "$_diag_release" ]] && _diag_release=$(env_get SNAPMULTI_RELEASE /opt/snapclient/.env none)
        [[ -z "$_diag_release" ]] && _diag_release="unknown"
        _diag_image_set=$(env_get SNAPMULTI_IMAGE_SET /opt/snapmulti/.env  none)
        [[ -z "$_diag_image_set" ]] && _diag_image_set=$(env_get SNAPMULTI_IMAGE_SET /opt/snapclient/.env none)
        [[ -z "$_diag_image_set" ]] && _diag_image_set="unknown"
        echo "snapmulti_release=$_diag_release"
        echo "snapmulti_image_set=$_diag_image_set"
        unset _diag_release _diag_image_set
    else
        echo "snapmulti_release=$( \
            (grep -m1 '^SNAPMULTI_RELEASE=' /opt/snapmulti/.env  2>/dev/null | cut -d= -f2-) \
            || (grep -m1 '^SNAPMULTI_RELEASE=' /opt/snapclient/.env 2>/dev/null | cut -d= -f2-) \
            || echo unknown)"
        echo "snapmulti_image_set=$( \
            (grep -m1 '^SNAPMULTI_IMAGE_SET=' /opt/snapmulti/.env  2>/dev/null | cut -d= -f2-) \
            || (grep -m1 '^SNAPMULTI_IMAGE_SET=' /opt/snapclient/.env 2>/dev/null | cut -d= -f2-) \
            || echo unknown)"
    fi
} > "$STAGE_DIR/meta.txt"

# release-manifest.json from the boot partition (no secrets, no
# scrubbing needed — but pass through anonymise for consistency with
# install.conf handling). Pinned to the SD-staged copy because that's
# the artefact that drove this install.
for candidate in /boot/firmware/snapmulti/release-manifest.json \
                 /boot/snapmulti/release-manifest.json \
                 /opt/snapmulti/release-manifest.json \
                 /opt/snapclient/release-manifest.json; do
    if [[ -f "$candidate" ]]; then
        {
            echo "# Source: $candidate"
            anonymise < "$candidate"
        } > "$STAGE_DIR/release-manifest.json"
        break
    fi
done

# install.conf copy (scrubbed). Look in all canonical locations.
for candidate in /boot/firmware/snapmulti/install.conf \
                 /boot/snapmulti/install.conf \
                 /opt/snapmulti/install.conf \
                 /opt/snapclient/install.conf; do
    if [[ -f "$candidate" ]]; then
        {
            echo "# Source: $candidate"
            anonymise < "$candidate"
        } > "$STAGE_DIR/install.conf"
        break
    fi
done

# Smoke output (JSON). device-smoke.sh exit-codes non-zero on warn/fail
# — we want the JSON regardless, so wrap with `|| true` and rely on the
# captured exit code in smoke.exit.
if command -v jq >/dev/null 2>&1; then
    smoke_path=""
    for candidate in /opt/snapmulti/scripts/device-smoke.sh \
                     /opt/snapclient/scripts/device-smoke.sh \
                     "$(dirname "$0")/device-smoke.sh"; do
        [[ -x "$candidate" ]] && { smoke_path="$candidate"; break; }
    done
    if [[ -n "$smoke_path" ]]; then
        log "Running $smoke_path --json --no-fail-on-warn"
        # `|| smoke_rc=$?` so set -e doesn't kill us on warn/fail exit codes.
        smoke_rc=0
        "$smoke_path" --json --no-fail-on-warn > "$STAGE_DIR/smoke.json" 2>"$STAGE_DIR/smoke.stderr" || smoke_rc=$?
        echo "$smoke_rc" > "$STAGE_DIR/smoke.exit"
    fi
else
    echo "jq not installed — device-smoke --json skipped" > "$STAGE_DIR/smoke.skipped"
fi

# Journalctl — last hour of snapMULTI-related units. -q to suppress
# "no journal files" warning that pollutes stderr on fresh boots.
if command -v journalctl >/dev/null 2>&1; then
    {
        journalctl --since "-1h" --no-pager -q \
            -u 'snapmulti-*' -u 'snapclient*' -u 'docker' -u 'avahi-daemon' \
            2>&1 | tail -2000 | anonymise
    } > "$STAGE_DIR/journal.log" || true
fi

# Install log — the most important diagnostic for install-failed bundles.
# Without this, a firstboot.sh failure leaves no trace of WHERE in the
# 12-step orchestration the failure occurred. journalctl only captures
# the systemd-unit output (cloud-init / snapmulti-firstboot.service);
# the per-module INFO/WARN/ERROR lines emitted via unified-log.sh land
# in this file and nowhere else. Tail to keep the bundle small —
# 5000 lines covers a full install run with verbose deploy output.
if [[ -f /var/log/snapmulti-install.log ]]; then
    tail -5000 /var/log/snapmulti-install.log 2>/dev/null \
        | anonymise > "$STAGE_DIR/install.log" || true
fi

# Docker compose logs — best-effort; only meaningful if docker is up.
if command -v docker >/dev/null 2>&1; then
    compose=""
    if [[ -n "$COMPOSE_FILE" ]]; then
        compose="$COMPOSE_FILE"
    else
        for candidate in /opt/snapmulti/docker-compose.yml \
                         /opt/snapclient/docker-compose.yml; do
            [[ -f "$candidate" ]] && { compose="$candidate"; break; }
        done
    fi
    if [[ -n "$compose" ]] && docker info >/dev/null 2>&1; then
        docker compose -f "$compose" logs --tail=200 --no-color 2>&1 \
            | anonymise > "$STAGE_DIR/docker.log" || true
        # State snapshot (running, restartcount, healthcheck).
        docker compose -f "$compose" ps --format json 2>/dev/null > "$STAGE_DIR/docker-ps.json" || true
    fi
fi

# Kernel ring buffer — dmesg may need root to read fully; tolerate
# partial output.
if command -v dmesg >/dev/null 2>&1; then
    dmesg 2>/dev/null | tail -300 | anonymise > "$STAGE_DIR/dmesg.log" || true
fi

# Loaded modules relevant to snapMULTI (audio, WiFi, fuse-overlayfs).
if command -v lsmod >/dev/null 2>&1; then
    lsmod 2>/dev/null | grep -E '^(snd|bcm|fuse|overlay|i2c|spi)' \
        > "$STAGE_DIR/modules.txt" || true
fi

# Hardware + cmdline snapshot. Everything here is small (<2 KB total).
# Each collector tolerates failure via `|| true` — under set -e a missing
# /proc file or grep with no matches would otherwise abort the bundle.
{
    echo "=== /proc/cmdline ==="
    cat /proc/cmdline 2>/dev/null || true
    echo ""
    echo "=== /etc/asound.conf ==="
    { [[ -f /etc/asound.conf ]] && cat /etc/asound.conf; } || true
    echo ""
    echo "=== vcgencmd ==="
    if command -v vcgencmd >/dev/null 2>&1; then
        echo "throttled=$(vcgencmd get_throttled 2>/dev/null || echo unknown)"
        echo "temp=$(vcgencmd measure_temp 2>/dev/null || echo unknown)"
        echo "memory_split arm=$(vcgencmd get_mem arm 2>/dev/null || echo unknown)"
        echo "memory_split gpu=$(vcgencmd get_mem gpu 2>/dev/null || echo unknown)"
    fi
    echo ""
    echo "=== /proc/cpuinfo (Hardware/Model lines only) ==="
    grep -E '^(Model|Hardware|Revision|Serial)' /proc/cpuinfo 2>/dev/null \
        | sed -E 's|(Serial[[:space:]]+:[[:space:]]+).*|\1[REDACTED]|' || true
    echo ""
    echo "=== overlayroot status ==="
    mount 2>/dev/null | grep -E ' on (/|/var) ' | head -5 || true
    echo ""
    echo "=== df / overlay tmpfs usage ==="
    df -h / /var 2>/dev/null | head -5 || true
} | anonymise > "$STAGE_DIR/hw.txt" || true
# /proc/cmdline carries firmware-injected device identifiers — most
# notably `smsc95xx.macaddr=<MAC>` on Pi 3 / 4 — that the file-level
# anonymise pass must rewrite. Earlier versions of this script piped
# only the journal / docker / dmesg streams through anonymise; hw.txt
# went through raw and leaked MAC addresses into every install-failed
# bundle. Pipe-on-write closes the gap without touching the
# per-section formatting above.

# ─── Bundle ──────────────────────────────────────────────────────────
mkdir -p "$OUT_DIR" 2>/dev/null || true
if ! tar -czf "$BUNDLE_PATH" -C "$WORK_DIR" "$BUNDLE_NAME" 2>"$WORK_DIR/tar.err"; then
    log "ERROR: tar failed:"
    cat "$WORK_DIR/tar.err" >&2
    exit 1
fi

# Best-effort size + path on stdout so callers can capture it.
size=$(du -h "$BUNDLE_PATH" 2>/dev/null | cut -f1 || echo "?")
log "Bundle written: $BUNDLE_PATH ($size)"
echo "$BUNDLE_PATH"
