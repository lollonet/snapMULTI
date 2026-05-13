#!/usr/bin/env bash
# Centralized Raspberry Pi hardware detection for snapMULTI.
#
# This is a sourced library, not a standalone executable. The shebang
# is kept only so editors / shellcheck identify the dialect correctly.
# Intentionally NO `set -euo pipefail` here — a sourced library would
# alter the caller's error mode, and snapMULTI callers tune that
# themselves: firstboot.sh / setup.sh use `set -euo pipefail`, ad-hoc
# operator scripts may rely on `set +e` to keep going past failures.
#
# Before this module the same `*"Zero 2 W"*` model match lived as
# byte-identical patterns in five callers (firstboot.sh,
# system-tune.sh in two functions, smoke/check_containers.sh,
# setup-zero2w.sh). A single typo in one of them would silently
# diverge profile dispatch from system tuning from smoke validation.
#
# Usage:
#   source scripts/common/device-detect.sh
#   if is_pi_zero_2w; then ... fi
#
# All predicates read /proc/device-tree/model with stderr suppressed
# and tolerate missing files (CI containers, unit-test environments).

# Read /proc/device-tree/model with the trailing NUL stripped.
# Returns the model string on stdout or an empty string on error.
# Cached for the lifetime of the shell — `/proc/device-tree/model`
# never changes between boots, and the firstboot orchestrator can
# call helpers dozens of times.
_DEVICE_MODEL_CACHE=""
_DEVICE_MODEL_READ=0
device_model() {
    if (( ! _DEVICE_MODEL_READ )); then
        _DEVICE_MODEL_CACHE=$(tr -d '\0' </proc/device-tree/model 2>/dev/null || echo "")
        _DEVICE_MODEL_READ=1
    fi
    printf '%s\n' "$_DEVICE_MODEL_CACHE"
}

# True iff this host is a Raspberry Pi Zero 2 W. The substring match
# accepts revisions (`Rev 1.0`, `Rev 1.1`, etc.) without needing
# updates per silicon spin.
is_pi_zero_2w() {
    [[ "$(device_model)" == *"Zero 2 W"* ]]
}
