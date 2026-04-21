#!/usr/bin/env bash
# Unified logging for snapMULTI install chain.
#
# Provides a single logging interface with:
#   - Timestamps (bash builtin, no fork)
#   - Log levels (INFO, WARN, ERROR, OK)
#   - Source identification (which module produced the line)
#   - Dual output: install log file + TUI progress feed
#   - Console output for errors/warnings on /dev/tty1
#
# Replaces both logging.sh and log_and_tty() from firstboot.sh.
#
# Usage:
#   LOG_SOURCE="network"
#   source scripts/common/unified-log.sh
#   log_info "Waiting for connectivity..."
#   log_warn "DNS not ready"
#   log_error "Network failed after 3 minutes"

# Log file destinations (can be overridden before sourcing)
UNIFIED_LOG="${UNIFIED_LOG:-/var/log/snapmulti-install.log}"
LOG_SOURCE="${LOG_SOURCE:-unknown}"

# Ensure log file exists and is writable
if [[ ! -f "$UNIFIED_LOG" ]]; then
    mkdir -p "$(dirname "$UNIFIED_LOG")" 2>/dev/null || true
    : > "$UNIFIED_LOG" 2>/dev/null || true
fi

# Core logging function — all output goes through here
log_msg() {
    local level="$1" source="${2:-$LOG_SOURCE}" msg="$3"

    # bash printf builtin for timestamps — no fork, fast on Pi Zero
    # Requires bash 4.2+ (Pi OS Bookworm ships 5.2+)
    printf '[%(%H:%M:%S)T] [%-5s] [%s] %s\n' -1 "$level" "$source" "$msg" \
        >> "$UNIFIED_LOG" 2>/dev/null || true

    # Feed TUI progress display (progress.sh reads this file)
    # All levels shown so warnings/errors are visible on the HDMI console
    if [[ -n "${PROGRESS_LOG:-}" ]]; then
        case "$level" in
            WARN)  echo "[WARN] $msg" >> "$PROGRESS_LOG" 2>/dev/null || true ;;
            ERROR) echo "[ERROR] $msg" >> "$PROGRESS_LOG" 2>/dev/null || true ;;
            *)     echo "$msg" >> "$PROGRESS_LOG" 2>/dev/null || true ;;
        esac
    fi

    # Show errors and warnings on HDMI console
    case "$level" in
        ERROR) echo "[ERROR] [$source] $msg" > /dev/tty1 2>/dev/null || true ;;
        WARN)  echo "[WARN]  [$source] $msg" > /dev/tty1 2>/dev/null || true ;;
    esac
}

# Convenience functions — set source automatically from LOG_SOURCE
log_info()  { log_msg INFO  "$LOG_SOURCE" "$*"; }
log_warn()  { log_msg WARN  "$LOG_SOURCE" "$*"; }
log_error() { log_msg ERROR "$LOG_SOURCE" "$*"; }
log_ok()    { log_msg OK    "$LOG_SOURCE" "$*"; }

# Backward compatibility with logging.sh (used by deploy.sh)
info()  { log_info "$@"; }
ok()    { log_ok "$@"; }
warn()  { log_warn "$@"; }
step()  { log_info "==> $*"; }

# Backward compatibility with firstboot.sh log_and_tty()
log_and_tty() {
    log_info "$*"
    echo "$*" > /dev/tty1 2>/dev/null || true
}
