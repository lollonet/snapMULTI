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

# Distro apt is the install source: Trixie ships snapclient 0.31.0,
# Bookworm ships 0.27.0. The badaix .deb release (v0.35) is Bookworm-
# bound by its libflac12 dependency and breaks on Trixie. The Snapcast
# wire protocol is stable across these minor versions, so the older
# apt build is acceptable for the Pi Zero 2W client. setup-zero2w.sh
# previously downloaded the .deb directly and pinned an SHA256; that
# path is removed (commit log for the rationale).
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

# ── Detect arch ──────────────────────────────────────────────────
if ! command -v dpkg >/dev/null 2>&1; then
    error "dpkg not found — this script requires Debian/Raspberry Pi OS"
    exit 1
fi
ARCH="$(dpkg --print-architecture)"
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

# ── snapclient install source ────────────────────────────────────
# Preferred: snapMULTI-built v0.35 .deb from GitHub releases (matches
# the server's snapcast version). Fallback: distro apt (Trixie 0.31,
# Bookworm 0.27 — wire-protocol compatible but older).
#
# The custom .deb release is named `snapclient-deb/<tag>` and ships
# four assets: snapclient_<ver>-snapmulti1_<arch>_<codename>.deb for
# trixie+bookworm × arm64+armhf. SHA256 verification is built into
# the release asset (`SHA256SUMS-*.txt`).
SNAPCLIENT_DEB_RELEASE_TAG="snapclient-deb/v0.35.0-snapmulti1"
SNAPCLIENT_DEB_RELEASE_BASEURL="https://github.com/lollonet/snapMULTI/releases/download/${SNAPCLIENT_DEB_RELEASE_TAG}"

_get_codename() {
    # shellcheck disable=SC1091
    if [[ -r /etc/os-release ]] && (. /etc/os-release && [[ -n "${VERSION_CODENAME:-}" ]]); then
        # shellcheck disable=SC1091
        (. /etc/os-release && printf '%s' "$VERSION_CODENAME")
        return 0
    fi
    return 1
}

install_snapclient_apt() {
    if dpkg-query -W -f='${Status}' snapclient 2>/dev/null | grep -q "install ok installed"; then
        local v
        v=$(dpkg-query -W -f='${Version}' snapclient 2>/dev/null || echo "?")
        ok "snapclient already installed (version $v)"
        return 0
    fi

    info "Installing snapclient from distro apt (fallback)"
    if ! DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends snapclient; then
        error "apt-get install snapclient failed — firstboot will retry on next boot"
        exit 1
    fi
    local v
    v=$(dpkg-query -W -f='${Version}' snapclient 2>/dev/null || echo "?")
    ok "snapclient installed (apt fallback, version $v)"
}

install_snapclient_custom_deb() {
    # Returns 0 on successful install of snapMULTI .deb; non-zero
    # signals the caller to fall back to apt distro.
    if dpkg-query -W -f='${Version}' snapclient 2>/dev/null | grep -q "snapmulti"; then
        local v
        v=$(dpkg-query -W -f='${Version}' snapclient 2>/dev/null || echo "?")
        ok "snapMULTI snapclient .deb already installed (version $v)"
        return 0
    fi

    local codename
    codename=$(_get_codename) || { warn "no /etc/os-release VERSION_CODENAME — fallback to apt"; return 1; }

    local deb_name="snapclient_0.35.0-snapmulti1_${ARCH}_${codename}.deb"
    local sums_name="SHA256SUMS-${codename}-${ARCH}.txt"
    local deb_url="${SNAPCLIENT_DEB_RELEASE_BASEURL}/${deb_name}"
    local sums_url="${SNAPCLIENT_DEB_RELEASE_BASEURL}/${sums_name}"
    local tmp_dir
    tmp_dir=$(mktemp -d /tmp/snapclient-deb-XXXXX)
    # Best-effort cleanup on any exit path.
    # shellcheck disable=SC2064
    trap "rm -rf '$tmp_dir'" RETURN

    info "Trying snapMULTI .deb: $deb_url"
    if ! curl -fL --retry 2 --max-time 90 -o "$tmp_dir/$deb_name" "$deb_url" 2>/dev/null; then
        info "snapMULTI .deb not available for ${codename}/${ARCH} — fallback to apt"
        return 1
    fi
    if ! curl -fL --retry 2 --max-time 30 -o "$tmp_dir/$sums_name" "$sums_url" 2>/dev/null; then
        warn "checksum file not available — refusing unsigned .deb, fallback to apt"
        return 1
    fi

    if ! ( cd "$tmp_dir" && grep "  ./${deb_name}\$" "$sums_name" | sha256sum -c --quiet ); then
        warn "snapMULTI .deb SHA256 mismatch — fallback to apt"
        return 1
    fi
    ok "SHA256 verified for $deb_name"

    if ! DEBIAN_FRONTEND=noninteractive dpkg -i "$tmp_dir/$deb_name"; then
        info "dpkg -i had missing deps — resolving with apt-get install -f"
        if ! DEBIAN_FRONTEND=noninteractive apt-get install -f -y; then
            warn "snapMULTI .deb dependency resolution failed — fallback to apt"
            return 1
        fi
    fi
    local v
    v=$(dpkg-query -W -f='${Version}' snapclient 2>/dev/null || echo "?")
    ok "snapclient installed from snapMULTI .deb (version $v)"
    return 0
}

step "Installing snapclient"
if ! install_snapclient_custom_deb; then
    install_snapclient_apt
fi

# ── Detect audio HAT ─────────────────────────────────────────────
# Resolves SOUNDCARD / MIXER from /proc/device-tree/hat (EEPROM) or
# the I2C bus scan in audio-hat-detect.sh. Without this, snapclient
# tries to open the bare "default" ALSA device which on a headless
# Pi Zero 2W is the HDMI controller — error 524.
SOUNDCARD="default"
MIXER="software"
ALSA_BUFFER_TIME="150"
ALSA_FRAGMENTS="4"
HAT_OVERLAY=""
HAT_NAME=""
HAT_CARD_NAME=""

_ensure_hat_detect_tools() {
    local missing=()
    command -v aplay     &>/dev/null || missing+=(alsa-utils)
    command -v i2cdetect &>/dev/null || missing+=(i2c-tools)
    command -v modprobe  &>/dev/null || missing+=(kmod)
    if (( ${#missing[@]} > 0 )); then
        info "Installing HAT detection tools: ${missing[*]}"
        DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${missing[@]}" >/dev/null 2>&1 || \
            warn "Could not install ${missing[*]} — HAT detection may fall back to internal-audio"
    fi
}

if _source_first_match "audio-hat-detect.sh"; then
    if command -v detect_hat &>/dev/null; then
        step "Detecting audio HAT"
        _ensure_hat_detect_tools
        # detect_hat prints the HAT_CONFIG name on stdout AND sets
        # HAT_DETECTION_SOURCE as a side-effect. Command substitution
        # `$(detect_hat)` would discard that side-effect (subshell scope),
        # so the log line below would always read "source: none" even on
        # a successful I2C / ALSA / EEPROM detection — observed live on
        # pizero where the PCM5122 was correctly found via I2C but the
        # log claimed the source was missing. Mirror the tempfile pattern
        # already used by setup.sh:279-285 so the global survives.
        _hat_tmp=$(mktemp /tmp/snapclient-hat-XXXXX)
        # shellcheck disable=SC2064  # we want $_hat_tmp expanded now
        trap "rm -f '$_hat_tmp'" RETURN EXIT
        if ! detect_hat 2>/dev/null > "$_hat_tmp"; then
            echo "internal-audio" > "$_hat_tmp"
        fi
        _hat_config=$(cat "$_hat_tmp")
        rm -f "$_hat_tmp"
        trap - RETURN EXIT
        _hat_config=$(resolve_hat_config_name "$_hat_config" 2>/dev/null || echo "$_hat_config")
        info "Detected HAT config: ${_hat_config} (source: ${HAT_DETECTION_SOURCE:-unknown})"

        # Load the per-HAT config file (HAT_NAME, HAT_OVERLAY, HAT_CARD_NAME,
        # HAT_MIXER, HAT_TYPE, HAT_FORMAT, HAT_RATE).
        _hat_conf_dirs=(
            "$SCRIPT_DIR/../audio-hats"
            "$SCRIPT_DIR/../../audio-hats"
            "/opt/snapclient/audio-hats"
        )
        _hat_conf_file=""
        for _d in "${_hat_conf_dirs[@]}"; do
            if [[ -f "$_d/${_hat_config}.conf" ]]; then
                _hat_conf_file="$_d/${_hat_config}.conf"
                break
            fi
        done
        if [[ -n "$_hat_conf_file" ]]; then
            # shellcheck disable=SC1090
            source "$_hat_conf_file"
            SOUNDCARD="${HAT_CARD_NAME:-$SOUNDCARD}"
            MIXER="${HAT_MIXER:-$MIXER}"
            ok "Loaded $_hat_conf_file (overlay=$HAT_OVERLAY, card=$HAT_CARD_NAME)"
        else
            warn "HAT config file not found for '${_hat_config}' — using ALSA defaults"
        fi
    fi
fi
info "SOUNDCARD=$SOUNDCARD MIXER=$MIXER ALSA_BUFFER_TIME=$ALSA_BUFFER_TIME ALSA_FRAGMENTS=$ALSA_FRAGMENTS"

# ── Configure /boot/firmware/config.txt for the HAT ──────────────
# Write the device-tree overlay so the kernel binds the audio HAT
# at next boot. Uses a marker-delimited block for idempotency.
# CRITICAL: bootloader parses config.txt WITHOUT supporting inline
# comments on `dtoverlay=` / `dtparam=` lines. Anything after the
# value (`# comment ...`) is treated as part of the value, and
# the overlay silently fails to load (only learned this the hard
# way on pizero 2026-05-12 — no overlay = HDMI-only audio =
# snapclient ALSA error 524 on headless).
if [[ -n "$HAT_OVERLAY" ]]; then
    step "Writing audio HAT overlay to /boot/firmware/config.txt"
    BOOT_CONFIG=""
    [[ -f /boot/firmware/config.txt ]] && BOOT_CONFIG=/boot/firmware/config.txt
    [[ -z "$BOOT_CONFIG" && -f /boot/config.txt ]] && BOOT_CONFIG=/boot/config.txt

    if [[ -n "$BOOT_CONFIG" ]]; then
        MARKER_START="# --- SNAPCLIENT ZERO2W AUDIO HAT START ---"
        MARKER_END="# --- SNAPCLIENT ZERO2W AUDIO HAT END ---"
        # Idempotent: strip any prior block, then re-emit.
        if grep -qF "$MARKER_START" "$BOOT_CONFIG"; then
            sed -i "/$MARKER_START/,/$MARKER_END/d" "$BOOT_CONFIG"
        fi
        # Comment out factory `dtparam=audio=on` so the firmware doesn't
        # emit `snd_bcm2835.enable_*` to /proc/cmdline twice (once from the
        # factory line, once from the `dtparam=audio=off` added below).
        # Audio runtime is unaffected (`audio=off` wins last anyway); this
        # only cleans the kernel cmdline. Idempotent via grep guard.
        if grep -qE '^dtparam=audio=on' "$BOOT_CONFIG"; then
            sed -i 's/^dtparam=audio=on/#dtparam=audio=on  # disabled by snapMULTI (HAT installed)/' "$BOOT_CONFIG"
        fi
        {
            echo ""
            echo "$MARKER_START"
            echo "# Audio HAT: $HAT_NAME"
            echo "# DO NOT add inline comments to dtoverlay/dtparam lines below — bootloader doesn't parse them."
            echo "dtparam=i2s=on"
            echo "dtoverlay=$HAT_OVERLAY"
            # Disable on-board HDMI audio so ALSA "default" doesn't latch to it.
            echo "dtparam=audio=off"
            echo "$MARKER_END"
        } >> "$BOOT_CONFIG"
        ok "Audio HAT overlay block written to $BOOT_CONFIG"

        # Best-effort runtime load so the smoke check + audio test in this
        # boot cycle see the card. If it fails, next reboot picks it up.
        if command -v dtoverlay &>/dev/null; then
            if dtoverlay "$HAT_OVERLAY" 2>/dev/null; then
                ok "Loaded $HAT_OVERLAY at runtime"
            else
                info "Runtime dtoverlay load skipped — overlay active after reboot"
            fi
        fi
    else
        warn "No /boot/firmware/config.txt found — HAT overlay not persisted"
    fi
fi

# ── /etc/asound.conf ─────────────────────────────────────────────
# Set the HAT card as the ALSA default so any client (snapclient or
# diagnostic tools like aplay) opens the right device without an
# explicit -D flag.
if [[ -n "$HAT_CARD_NAME" ]]; then
    step "Writing /etc/asound.conf"
    cat > /etc/asound.conf <<EOF
# Generated by snapMULTI setup-zero2w.sh — Audio HAT: $HAT_NAME
pcm.!default {
    type plug
    slave.pcm "hw:CARD=$HAT_CARD_NAME,DEV=0"
}
ctl.!default {
    type hw
    card $HAT_CARD_NAME
}
EOF
    ok "/etc/asound.conf points to $HAT_CARD_NAME"
fi

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
# firstboot.sh already promoted INSTALL_TYPE=client -> client-native
# before invoking this script, so the install.conf on the boot
# partition is the canonical source. We just mirror it (+ runtime
# extras like SNAPCLIENT_VERSION) under /opt/snapclient/ so the
# device-smoke modules can `grep INSTALL_TYPE` without reaching
# back to the boot partition. The write is guarded — if the disk
# is full or has gone read-only we fail loudly rather than leaving
# a half-written marker that confuses smoke at the next boot.
mkdir -p "$INSTALL_DIR"
_apt_snapclient_ver=$(dpkg-query -W -f='${Version}' snapclient 2>/dev/null || echo "unknown")
if ! cat > "$INSTALL_DIR/install.conf" <<EOF
# snapMULTI install marker — mirrored from firstboot's install.conf.
# INSTALL_TYPE is promoted by firstboot.sh based on device model
# (client + Pi Zero 2W -> client-native). This file is the on-device
# canonical copy consumed by device-smoke.sh and check_containers.sh.
INSTALL_TYPE=client-native
CLIENT_ID=${CLIENT_ID}
SNAPCLIENT_VERSION=${_apt_snapclient_ver}
ARCH=${ARCH}
EOF
then
    error "Failed to write $INSTALL_DIR/install.conf — disk full or filesystem read-only?"
    error "Smoke checks will not detect this as a native-client install."
    exit 1
fi
unset _apt_snapclient_ver

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
