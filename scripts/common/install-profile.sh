#!/usr/bin/env bash
# Sourced as a function library; `set -euo pipefail` intentionally omitted
# to avoid altering the calling shell's error mode. Functions return
# success/failure via exit code (0 = true, 1 = false) or echo a value to
# stdout. Callers MUST quote arguments — type strings are external input.
#
# install-profile.sh — SSOT for install-type derived decisions.
#
# Today these decisions are scattered:
#   - `INSTALL_TYPE == "server" || INSTALL_TYPE == "both"` repeated 8+
#     times across firstboot.sh and prepare-sd.sh
#   - `is_client_install` inline in firstboot.sh:219, not callable from
#     prepare-sd or other consumers
#   - Pi Zero 2W → client-native promotion inline in firstboot.sh:211
#   - "needs Docker" / "needs music source" / "needs readonly" implicit
#     in case branches, never named
#
# This module centralises the predicates. Pure (no I/O except logging on
# error) so it's trivial to unit-test. Does NOT read install.conf — the
# caller is responsible for sourcing the raw type and passing it in;
# only `install_profile_resolve` consults hardware (via device-detect.sh).
#
# Valid types: client | client-native | server | both
#
# CONTRACT FOR CALLERS:
#   Invalid type strings (typos, corrupt install.conf, empty value) make
#   the `needs_*` predicates return FALSE silently — by design, so the
#   library stays a pure function table. The caller MUST gate on
#   `install_profile_is_valid "$INSTALL_TYPE"` BEFORE branching on any
#   predicate, and fail loud (log_error + exit 1) on rejection. Otherwise
#   a malformed INSTALL_TYPE leads to "needs_docker=false, needs_*_stack=
#   false" silently, i.e. an install that does nothing and reports success.
#   Today firstboot.sh:292-294 has the `*) log_error "Unknown INSTALL_TYPE"`
#   case at the dispatch point — when PR2 migrates call sites, this guard
#   must be preserved (gate FIRST, predicate SECOND).

_install_profile_warn() {
    if declare -F warn >/dev/null 2>&1; then
        warn "$@"
    else
        echo "WARN: $*" >&2
    fi
}

install_profile_is_valid() {
    case "${1:-}" in
        client|client-native|server|both) return 0 ;;
        *) return 1 ;;
    esac
}

# Apply the Pi Zero 2W → client-native promotion. Echoes the resolved
# type to stdout. Falls through unchanged if either the type is not
# `client` or hardware detection (`is_pi_zero_2w`) is not available /
# returns false.
#
# Caller must source scripts/common/device-detect.sh first if it wants
# the promotion to actually fire — when the function is missing this
# helper logs once on stderr and echoes the input unchanged (so unit
# tests on CI runners without /proc/device-tree behave deterministically).
install_profile_resolve() {
    local raw_type="${1:-}"
    if ! install_profile_is_valid "$raw_type"; then
        _install_profile_warn "install_profile_resolve: invalid type '$raw_type'"
        echo "$raw_type"
        return 1
    fi

    if [[ "$raw_type" == "client" ]] && \
       declare -F is_pi_zero_2w >/dev/null 2>&1 && \
       is_pi_zero_2w; then
        echo "client-native"
        return 0
    fi

    echo "$raw_type"
}

# True for any profile that brings up the audio player — containerised
# (client) or native (client-native), plus the both-mode where the
# client stack runs alongside the server stack.
install_profile_is_client() {
    case "${1:-}" in
        client|client-native|both) return 0 ;;
        *) return 1 ;;
    esac
}

# True for any profile that brings up the server stack (snapserver +
# MPD + metadata-service + Spotify + AirPlay + Tidal[ARM] + myMPD).
install_profile_needs_server_stack() {
    case "${1:-}" in
        server|both) return 0 ;;
        *) return 1 ;;
    esac
}

# True for any profile that brings up the client stack (snapclient +
# fb-display + audio-visualizer on Pi 3/4/5, or `snapclient.service`
# native on Pi Zero 2W).
install_profile_needs_client_stack() {
    case "${1:-}" in
        client|client-native|both) return 0 ;;
        *) return 1 ;;
    esac
}

# True for any profile that uses Docker. client-native runs snapclient
# directly under systemd to fit in 512 MB on Pi Zero 2W — every other
# profile pulls fuse-overlayfs + Docker engine + the upstream images.
install_profile_needs_docker() {
    case "${1:-}" in
        client|server|both) return 0 ;;
        client-native) return 1 ;;
        *) return 1 ;;
    esac
}

# True for profiles that CONFIGURE a music source at install time —
# `prepare-sd.sh` shows the music-source menu, `firstboot.sh` mounts
# NFS/SMB or sets up the local library. This is install-time
# configuration, NOT runtime music availability: client / client-native
# profiles consume snapserver's audio stream at runtime but do not
# configure their own source. Today: server + both.
install_profile_configures_music_source() {
    case "${1:-}" in
        server|both) return 0 ;;
        *) return 1 ;;
    esac
}

# Hardware × profile gate. Pi Zero 2W (512 MB RAM, single-core SDIO
# storage) cannot host the server stack — verified OOM on early
# attempts before the rule was discovered. The native snapclient path
# (which the promote step transforms `client` into) is the only viable
# mode on Pi Zero 2W. Returns 0 (OK) when the combination is supported,
# 1 (REJECT) when it is not.
#
# Like `install_profile_resolve`, this falls back to "OK" when
# `is_pi_zero_2w` is unavailable — unit tests on non-Pi runners don't
# block, matching the existing `_validate_profile_hardware` behaviour.
install_profile_hardware_ok() {
    local type="${1:-}"
    if ! install_profile_is_valid "$type"; then
        return 1
    fi
    if ! declare -F is_pi_zero_2w >/dev/null 2>&1; then
        return 0
    fi
    if ! is_pi_zero_2w; then
        return 0
    fi
    case "$type" in
        server|both) return 1 ;;
        *) return 0 ;;
    esac
}
