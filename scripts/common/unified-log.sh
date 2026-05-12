#!/usr/bin/env bash
# Unified logging for snapMULTI — single source of truth for all bash output.
#
# Two operating modes, auto-detected at source time:
#
#   1. INSTALL CHAIN MODE (firstboot.sh, deploy.sh, setup.sh under firstboot):
#      $UNIFIED_LOG file is writable → log lines are timestamped and appended
#      to the install log. ERROR/WARN are also mirrored to $PROGRESS_TTY so
#      they are visible on the HDMI console under the TUI.
#
#   2. INTERACTIVE MODE (status.sh, device-smoke.sh, deploy.sh on dev host):
#      $UNIFIED_LOG is not writable → log lines fall back to stderr with
#      ANSI colors when stderr is a terminal. This preserves the legacy
#      logging.sh behaviour for one-shot CLI use.
#
# Replaces both logging.sh and log_and_tty() from firstboot.sh.
#
# Usage:
#   LOG_SOURCE="network"
#   source scripts/common/unified-log.sh
#   log_info "Waiting for connectivity..."
#   log_warn "DNS not ready"
#   log_error "Network failed after 3 minutes"
#
# Legacy aliases (info/ok/warn/error/step/debug) are provided for back-compat
# with logging.sh — no caller migration required.

# Log file destinations (can be overridden before sourcing)
UNIFIED_LOG="${UNIFIED_LOG:-/var/log/snapmulti-install.log}"
LOG_SOURCE="${LOG_SOURCE:-unknown}"

# Console TTY for ERROR/WARN visibility. firstboot.sh sets this to /dev/tty3
# so the install log doesn't overlap fb-display rendering on /dev/tty1 / fb0.
PROGRESS_TTY="${PROGRESS_TTY:-/dev/tty1}"

# Probe whether we can write to the unified log. The probe doubles as
# initialisation — successful mkdir+touch leaves an empty log ready for
# append. Failure is silent; falls back to stderr-only output below.
#
# `{ ...; } 2>/dev/null` wraps the redirect itself so bash's own
# "Permission denied" message is captured — a bare `2>/dev/null` after
# the redirect target does not catch shell-level redirect errors.
_UNIFIED_LOG_WRITABLE=0
if mkdir -p "$(dirname "$UNIFIED_LOG")" 2>/dev/null \
   && { : >> "$UNIFIED_LOG"; } 2>/dev/null; then
    _UNIFIED_LOG_WRITABLE=1
fi

# Stderr fallback colours — applied only when stderr is a real terminal
# (interactive CLI). Under cloud-init/systemd, stderr goes to the journal
# and we emit plain text. Mirrors the colour scheme of the legacy
# logging.sh so interactive scripts (status.sh, device-smoke.sh) keep
# their familiar look.
if [[ -t 2 ]]; then
    _LOG_RED=$'\033[0;31m'
    _LOG_GREEN=$'\033[0;32m'
    _LOG_YELLOW=$'\033[1;33m'
    _LOG_BLUE=$'\033[0;34m'
    _LOG_CYAN=$'\033[0;36m'
    _LOG_BOLD=$'\033[1m'
    _LOG_NC=$'\033[0m'
else
    _LOG_RED=''
    _LOG_GREEN=''
    _LOG_YELLOW=''
    _LOG_BLUE=''
    _LOG_CYAN=''
    _LOG_BOLD=''
    _LOG_NC=''
fi

# Core logging function — all output flows through here.
log_msg() {
    local level="$1" source="${2:-$LOG_SOURCE}" msg="$3"

    if (( _UNIFIED_LOG_WRITABLE )); then
        # bash printf builtin for timestamps — no fork, fast on Pi Zero.
        # Requires bash 4.2+ (Pi OS Bookworm ships 5.2+).
        # `{ ...; } 2>/dev/null` silences bash-level redirect errors
        # (e.g. disk full, permission revoked after the probe) — a bare
        # `2>/dev/null` after the redirect target does NOT.
        { printf '[%(%H:%M:%S)T] [%-5s] [%s] %s\n' -1 "$level" "$source" "$msg" \
            >> "$UNIFIED_LOG"; } 2>/dev/null || true

        # Feed TUI progress display (progress.sh reads this file).
        if [[ -n "${PROGRESS_LOG:-}" ]]; then
            case "$level" in
                WARN)  { echo "[WARN] $msg"  >> "$PROGRESS_LOG"; } 2>/dev/null || true ;;
                ERROR) { echo "[ERROR] $msg" >> "$PROGRESS_LOG"; } 2>/dev/null || true ;;
                *)     { echo "$msg"          >> "$PROGRESS_LOG"; } 2>/dev/null || true ;;
            esac
        fi

        # Mirror ERROR/WARN to the HDMI console. PROGRESS_TTY may not be
        # writable from non-root context or in CI; wrap to silence.
        case "$level" in
            ERROR) { echo "[ERROR] [$source] $msg" > "$PROGRESS_TTY"; } 2>/dev/null || true ;;
            WARN)  { echo "[WARN]  [$source] $msg" > "$PROGRESS_TTY"; } 2>/dev/null || true ;;
        esac
    else
        # Interactive fallback: coloured stderr. Matches the format of the
        # legacy logging.sh so existing CLI scripts look unchanged.
        case "$level" in
            INFO)  echo -e "${_LOG_BLUE}[INFO]${_LOG_NC} $msg"   >&2 ;;
            OK)    echo -e "${_LOG_GREEN}[OK]${_LOG_NC} $msg"    >&2 ;;
            WARN)  echo -e "${_LOG_YELLOW}[WARN]${_LOG_NC} $msg" >&2 ;;
            ERROR) echo -e "${_LOG_RED}[ERROR]${_LOG_NC} $msg"   >&2 ;;
            DEBUG) [[ "${DEBUG:-0}" == "1" ]] && echo -e "[DEBUG] $msg" >&2 ;;
            *)     echo "[$level] $msg" >&2 ;;
        esac
    fi
}

# Convenience functions — set source automatically from LOG_SOURCE
log_info()  { log_msg INFO  "$LOG_SOURCE" "$*"; }
log_warn()  { log_msg WARN  "$LOG_SOURCE" "$*"; }
log_error() { log_msg ERROR "$LOG_SOURCE" "$*"; }
log_ok()    { log_msg OK    "$LOG_SOURCE" "$*"; }

# Backward compatibility with logging.sh — full API parity.
info()  { log_info "$@"; }
ok()    { log_ok "$@"; }
warn()  { log_warn "$@"; }
error() { log_error "$@"; }
debug() { log_msg DEBUG "$LOG_SOURCE" "$*"; }
step() {
    # step() emits a banner-style line. In interactive mode keep the
    # cyan/bold header for visual separation; in install-chain mode it
    # collapses to a tagged INFO line.
    if (( _UNIFIED_LOG_WRITABLE )); then
        log_info "==> $*"
    else
        echo -e "\n${_LOG_CYAN}${_LOG_BOLD}==> $*${_LOG_NC}" >&2
    fi
}

# Backward compatibility with firstboot.sh log_and_tty()
log_and_tty() {
    log_info "$*"
    { echo "$*" > "$PROGRESS_TTY"; } 2>/dev/null || true
}
