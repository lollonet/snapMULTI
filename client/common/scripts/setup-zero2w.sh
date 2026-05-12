#!/usr/bin/env bash
# setup-zero2w.sh — Pi Zero 2W native snapclient install (no Docker)
#
# Context: Pi Zero 2W has 512 MB RAM. The container stack
# (snapclient 64M + audio-visualizer 128M + fb-display 192M = 384M)
# plus dockerd (~80 MB) plus the OS exceeds the available memory.
# docs/HARDWARE.md already lists Pi Zero 2W as unsupported for client
# with display; in practice it is headless-only. This script installs
# snapclient natively from the upstream badaix/snapcast .deb release,
# skipping Docker entirely.
#
# Invoked by scripts/firstboot.sh when /proc/device-tree/model
# matches "Zero 2 W". The standard scripts/setup.sh stays untouched
# for all other client models.
#
# Sibling: scripts/common/system-tune.sh::tune_pi_zero_2w_swap_safety()
# masks zram swap services to prevent overlay tmpfs fill — that fix
# is wired into firstboot.sh BEFORE setup.sh runs (must precede
# overlayroot activation).

set -euo pipefail

SNAPCLIENT_VERSION="0.35.0"
SNAPCLIENT_DEB_REV="0.35.0-1"
SNAPCLIENT_DEB_BASEURL="https://github.com/badaix/snapcast/releases/download/v${SNAPCLIENT_VERSION}"
# SHA256 of the upstream .deb assets (pinned 2026-05-12).
# Re-pin on every snapcast release bump.
SNAPCLIENT_SHA256_ARM64="83afa0910cce99c0e6d4a52ec1849240c9956f5147e0743d60d4dd5f3b11af1a"
SNAPCLIENT_SHA256_ARMHF="b532928974d5fa1bef8aa44e7400fb47ee3e91cede319c90cf830d23cf18ddb2"

INSTALL_DIR="/opt/snapclient"
CLIENT_ID="snapclient-$(hostname)"

# ── Locate common libs ───────────────────────────────────────────
# Script can be invoked from either the source tree (during dev)
# or from /opt/snapclient/scripts on a real device. Probe both.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Handle --help before sourcing anything: callable from any context,
# no root required, no dependencies on logging.sh.
for _arg in "$@"; do
    case "$_arg" in
        --help|-h)
            cat <<EOF
Usage: setup-zero2w.sh [--auto] [--no-readonly] [config_file]

Pi Zero 2W native snapclient install (no Docker).

Flags:
  --auto         Non-interactive (firstboot entry mode)
  --no-readonly  Skip overlayroot activation
  --help, -h     Show this help and exit
EOF
            exit 0
            ;;
    esac
done
unset _arg

_source_first_match() {
    local target="$1"
    local cand
    for cand in \
        "$SCRIPT_DIR/$target" \
        "$SCRIPT_DIR/common/$target" \
        "$SCRIPT_DIR/../../scripts/common/$target" \
        "$SCRIPT_DIR/../scripts/common/$target" \
        "/opt/snapclient/scripts/common/$target"; do
        # shellcheck disable=SC1090
        if [[ -f "$cand" ]]; then
            source "$cand"
            return 0
        fi
    done
    return 1
}

_source_first_match "logging.sh" || { echo "FATAL: cannot find logging.sh" >&2; exit 1; }

# ── Args ─────────────────────────────────────────────────────────
# --auto is the firstboot entry mode (no-op flag, kept for symmetry
# with setup.sh; the script behaves the same with or without it).
# --help is handled earlier (pre-source) for safe invocation.
ENABLE_READONLY="true"
for arg in "$@"; do
    case "$arg" in
        --auto) : ;;
        --no-readonly) ENABLE_READONLY="false" ;;
    esac
done

step "Pi Zero 2W native snapclient setup"
info "Client ID: $CLIENT_ID"
info "snapclient version: v${SNAPCLIENT_VERSION}"

# ── Detect arch ──────────────────────────────────────────────────
if ! command -v dpkg >/dev/null 2>&1; then
    error "dpkg not found — this script requires Debian/Raspberry Pi OS"
    exit 1
fi
ARCH="$(dpkg --print-architecture)"
case "$ARCH" in
    arm64) EXPECTED_SHA="$SNAPCLIENT_SHA256_ARM64" ;;
    armhf) EXPECTED_SHA="$SNAPCLIENT_SHA256_ARMHF" ;;
    *)
        error "Unsupported architecture for snapclient .deb: $ARCH"
        exit 1
        ;;
esac
DEB_URL="${SNAPCLIENT_DEB_BASEURL}/snapclient_${SNAPCLIENT_DEB_REV}_${ARCH}_bookworm.deb"
info "Architecture: $ARCH"

# ── Install runtime deps via shared install-deps.sh ──────────────
# Reuses the same dependency list (avahi-daemon, locales, monitoring
# tools, etc.) used by the Docker path — keeps the device feel
# identical except for the snapclient runtime itself.
if _source_first_match "install-deps.sh"; then
    if command -v install_dependencies &>/dev/null; then
        step "Installing system dependencies"
        install_dependencies
    fi
fi

# Extra runtime deps specific to native snapclient (the .deb declares
# these as Depends but apt-get install -f resolves them anyway; we
# pre-install to keep the dpkg -i call fast and idempotent).
step "Pre-installing snapclient runtime libraries"
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    libasound2 libavahi-client3 libavahi-common3 libflac12 \
    libogg0 libopus0 libsoxr0 libssl3 libvorbis0a \
    alsa-utils avahi-daemon curl ca-certificates adduser

# ── Install snapclient .deb (idempotent) ─────────────────────────
install_snapclient_deb() {
    local installed_ver=""
    if command -v snapclient >/dev/null 2>&1; then
        installed_ver="$(/usr/bin/snapclient --version 2>&1 | head -1 || true)"
        if echo "$installed_ver" | grep -qE "v?${SNAPCLIENT_VERSION//./\\.}"; then
            ok "snapclient v${SNAPCLIENT_VERSION} already installed"
            return 0
        fi
        info "snapclient currently installed: $installed_ver (will upgrade)"
    fi

    local deb_path=/tmp/snapclient.deb
    info "Downloading $DEB_URL"
    if ! curl -fL --retry 3 --max-time 180 -o "$deb_path" "$DEB_URL"; then
        error "snapclient .deb download failed — firstboot will retry on next boot"
        rm -f "$deb_path"
        exit 1
    fi

    local actual_sha
    actual_sha="$(sha256sum "$deb_path" | awk '{print $1}')"
    if [[ "$actual_sha" != "$EXPECTED_SHA" ]]; then
        error "snapclient .deb SHA256 mismatch:"
        error "  expected: $EXPECTED_SHA"
        error "  actual:   $actual_sha"
        rm -f "$deb_path"
        exit 1
    fi
    ok "SHA256 verified ($actual_sha)"

    if ! DEBIAN_FRONTEND=noninteractive dpkg -i "$deb_path"; then
        info "dpkg -i reported missing deps — resolving with apt-get install -f"
        if ! DEBIAN_FRONTEND=noninteractive apt-get install -f -y; then
            error "snapclient .deb dependency resolution failed"
            rm -f "$deb_path"
            exit 1
        fi
    fi
    rm -f "$deb_path"
    ok "snapclient v${SNAPCLIENT_VERSION} installed"
}

step "Installing snapclient .deb"
install_snapclient_deb

# ── Detect audio HAT (sets SOUNDCARD / MIXER / ALSA_*) ───────────
SOUNDCARD="default"
MIXER="software"
ALSA_BUFFER_TIME="150"
ALSA_FRAGMENTS="4"

if _source_first_match "audio-hat-detect.sh"; then
    if command -v detect_audio_hat &>/dev/null; then
        step "Detecting audio HAT"
        # detect_audio_hat exports SOUNDCARD / MIXER / ALSA_BUFFER_TIME /
        # ALSA_FRAGMENTS based on the EEPROM / I2C scan results.
        detect_audio_hat || warn "Audio HAT detection failed — using default ALSA device"
    fi
fi
info "SOUNDCARD=$SOUNDCARD MIXER=$MIXER ALSA_BUFFER_TIME=$ALSA_BUFFER_TIME ALSA_FRAGMENTS=$ALSA_FRAGMENTS"

# ── Configure /etc/default/snapclient ────────────────────────────
# The .deb ships /etc/default/snapclient as a conffile. We rewrite
# it with snapMULTI's options. dpkg will prompt on .deb upgrade if
# the file changed — acceptable under our reflash-only policy
# (DEC-003): in-place upgrades are not supported.
step "Writing /etc/default/snapclient"
cat > /etc/default/snapclient <<EOF
# Generated by snapMULTI setup-zero2w.sh — do not edit by hand
# Re-run setup-zero2w.sh to regenerate after upgrades.
START_SNAPCLIENT=true
SNAPCLIENT_OPTS="--hostID ${CLIENT_ID} --soundcard ${SOUNDCARD} --mixer ${MIXER} --player alsa:buffer_time=${ALSA_BUFFER_TIME}:fragments=${ALSA_FRAGMENTS}"
EOF
ok "/etc/default/snapclient configured"

# ── systemd drop-in override ─────────────────────────────────────
# The .deb ships /lib/systemd/system/snapclient.service with
# User=snapclient Group=snapclient and Restart=on-failure. We layer
# a drop-in to add restart limits, real-time audio scheduling, and
# explicit network ordering. Drop-ins survive .deb upgrades cleanly.
step "Installing systemd drop-in override"
DROPIN_DIR=/etc/systemd/system/snapclient.service.d
mkdir -p "$DROPIN_DIR"
cat > "$DROPIN_DIR/snapmulti-override.conf" <<'EOF'
# Drop-in override installed by snapMULTI setup-zero2w.sh.
# Layered on top of the upstream snapclient.service shipped by the
# badaix snapcast .deb. Survives .deb upgrades.

[Unit]
After=network-online.target avahi-daemon.service sound.target
Wants=network-online.target avahi-daemon.service
StartLimitBurst=5
StartLimitIntervalSec=300

[Service]
Restart=on-failure
RestartSec=5
LimitRTPRIO=10
LimitMEMLOCK=infinity
EOF
ok "systemd drop-in installed at $DROPIN_DIR/snapmulti-override.conf"

# ── Enable + start ───────────────────────────────────────────────
step "Enabling and starting snapclient.service"
systemctl daemon-reload
systemctl enable snapclient.service >/dev/null 2>&1 || true
if ! systemctl restart snapclient.service; then
    warn "snapclient.service restart failed — diagnostics: journalctl -u snapclient -n 50"
fi

# ── Verify ───────────────────────────────────────────────────────
sleep 3
if systemctl is-active --quiet snapclient.service; then
    ok "snapclient.service active"
else
    warn "snapclient.service is not active (state: $(systemctl is-active snapclient.service || true))"
    info "Last 20 journal lines:"
    journalctl -u snapclient -n 20 --no-pager 2>&1 | sed 's/^/  /' >&2 || true
fi

# ── Install snapMULTI install dir marker (for smoke checks) ─────
mkdir -p "$INSTALL_DIR"
cat > "$INSTALL_DIR/install.conf" <<EOF
# snapMULTI install marker — written by setup-zero2w.sh
INSTALL_TYPE=client-native
CLIENT_ID=${CLIENT_ID}
SNAPCLIENT_VERSION=${SNAPCLIENT_VERSION}
ARCH=${ARCH}
EOF

# ── Strip Docker-only assets staged by prepare-sd.sh ─────────────
# prepare-sd.sh ships the full client tree without knowing the
# target model. On Pi Zero 2W the native path uses none of the
# Docker artefacts (compose file, Dockerfiles, bind-mount sources
# for visualizer/fb-display, display-detect helpers). Removing
# them after the install keeps the device tree honest: a smoke
# check or operator browsing /opt/snapclient/ won't be misled by
# obsolete config that would not actually be honoured.
step "Pruning Docker-only assets (not used by native install)"
for unused in \
    "$INSTALL_DIR/docker-compose.yml" \
    "$INSTALL_DIR/.env.example" \
    "$INSTALL_DIR/docker" \
    "$INSTALL_DIR/public" \
    "$INSTALL_DIR/scripts/discover-server.sh" \
    "$INSTALL_DIR/scripts/display.sh" \
    "$INSTALL_DIR/scripts/display-detect.sh" \
    "$INSTALL_DIR/scripts/docker-driver-reconcile.sh" \
    "$INSTALL_DIR/scripts/common/install-docker.sh" \
    "$INSTALL_DIR/systemd/snapclient-display.service"; do
    rm -rf "$unused" 2>/dev/null || true
done
ok "Docker-only assets pruned"

# ── Read-only filesystem ─────────────────────────────────────────
# Defer overlayroot activation to firstboot.sh's setup_readonly_fs
# step — same as the Docker path. setup-zero2w.sh deliberately does
# NOT call raspi-config nonint do_overlayfs 0 here. Firstboot will
# enable overlayroot AFTER this script returns, by which point the
# zram mask symlinks (installed pre-overlayroot by
# tune_pi_zero_2w_swap_safety) are already in the underlying ext4.

if [[ "$ENABLE_READONLY" == "false" ]]; then
    info "Read-only filesystem disabled (--no-readonly)"
fi

step "Pi Zero 2W native snapclient setup complete"
info "Service:  systemctl status snapclient"
info "Logs:     journalctl -u snapclient -f"
info "Config:   /etc/default/snapclient"
info "Override: $DROPIN_DIR/snapmulti-override.conf"

exit 0
