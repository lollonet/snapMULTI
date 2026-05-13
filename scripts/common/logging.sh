#!/usr/bin/env bash
# DEPRECATED: thin shim that sources scripts/common/unified-log.sh.
#
# unified-log.sh is the single source of truth for snapMULTI logging since
# v0.7.x. It auto-detects install-chain vs interactive mode and provides
# both the legacy logging.sh API (info/ok/warn/error/step/debug, coloured
# stderr) and the install-chain API (log_info/log_warn/log_error/log_ok/
# log_and_tty, timestamped file + TUI feed + PROGRESS_TTY mirror).
#
# Existing callers (deploy.sh, status.sh, device-smoke.sh, system-tune.sh,
# prepare-sd.sh) continue to work unchanged. New code should source
# unified-log.sh directly.

_LOGGING_SHIM_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=unified-log.sh
# shellcheck disable=SC1091
source "$_LOGGING_SHIM_DIR/unified-log.sh"
unset _LOGGING_SHIM_DIR
