#!/usr/bin/env bash
# shellcheck disable=SC2016  # assert() conditions are eval'd, single quotes intentional.
#
# Static checks for the install_dependencies redundancy guards.
#
# Background: firstboot.sh runs `install_dependencies` once for the whole
# host (the only place that does the apt-get update + full upgrade). Then
# it dispatches to deploy.sh (server) and/or setup.sh (client). Both
# children also source install-deps.sh and historically called
# `install_dependencies` themselves — idempotent but ~30-60s per call,
# and on Pi Zero 2W the redundant apt index rebuild risks transient
# tmpfs ENOSPC. The guard pattern (introduced in setup.sh during the
# Wave 4 hardening, mirrored here in deploy.sh) skips the second pass
# when:
#   - PROGRESS_MANAGED=1 (firstboot is the parent — it already ran the
#     full pass)
#   - the essential commands (docker / curl / avahi-daemon) are present
#
# Standalone runs (advanced users invoking deploy.sh or setup.sh
# directly without firstboot) keep the full pass.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY="$SCRIPT_DIR/../scripts/deploy.sh"
SETUP="$SCRIPT_DIR/../client/common/scripts/setup.sh"

pass=0
fail=0

assert() {
    local cond="$1" desc="$2"
    if eval "$cond"; then
        echo "  PASS: $desc"
        pass=$((pass + 1))
    else
        echo "  FAIL: $desc"
        fail=$((fail + 1))
    fi
}

echo "=== deploy.sh — PROGRESS_MANAGED guard around install_dependencies ==="

# Walk setup_server_host() and assert the guard is present.
deploy_block=$(awk '/^setup_server_host\(\)/,/^}/' "$DEPLOY")

assert 'echo "$deploy_block" | grep -qE "PROGRESS_MANAGED"' \
       'setup_server_host references PROGRESS_MANAGED'

# Mirror setup.sh:474 which uses non-empty `-n` check, not strict
# `== "1"` equality. A future caller passing PROGRESS_MANAGED=yes or
# =true would silently bypass the guard under strict equality while
# setup.sh still skips — and the comment claims they mirror.
assert 'echo "$deploy_block" | grep -qE "\\[\\[ -n \"\\\$\\{PROGRESS_MANAGED:-\\}\""' \
       'guard uses `-n` non-empty check (mirrors setup.sh:474)'

assert 'echo "$deploy_block" | grep -qE "command -v docker"' \
       'guard checks docker is already installed'

assert 'echo "$deploy_block" | grep -qE "command -v curl"' \
       'guard checks curl is already installed'

assert 'echo "$deploy_block" | grep -qE "command -v avahi-daemon"' \
       'guard checks avahi-daemon is already installed'

assert 'echo "$deploy_block" | grep -qE "INSTALL_ROLE=server.*install_dependencies"' \
       'standalone path still runs install_dependencies for server role'

# Skip message must be informative — we want to see it in firstboot logs
# when the guard fires (helps diagnose "why was the apt pass skipped?").
assert 'echo "$deploy_block" | grep -qE "Skipping install_dependencies"' \
       'guard logs an explicit Skipping... message'

echo
echo "=== setup.sh — existing PROGRESS_MANAGED guard (regression test) ==="

# setup.sh has had this guard since Wave 4. Reassert it so a future
# refactor can't quietly drop it.
setup_block=$(awk '/install-deps\.sh/{found=1} found && /^fi[[:space:]]*$/{print; exit} found{print}' "$SETUP" | head -40)

assert 'echo "$setup_block" | grep -qE "PROGRESS_MANAGED"' \
       'setup.sh still references PROGRESS_MANAGED'

assert 'echo "$setup_block" | grep -qE "INSTALL_ROLE=client"' \
       'standalone path still sets INSTALL_ROLE=client'

echo
echo "=== install-deps.sh: post-install cleanup ==="
INSTALL_DEPS="$SCRIPT_DIR/../scripts/common/install-deps.sh"
# Verify autoremove --purge fires at the end of install_dependencies().
# Without this, fresh Pi OS images drag in mesa/wayland/X11/GL libs as
# Recommends from packages that get later orphaned — observed live on
# pizero: 19 stale auto-installed packages flagged by apt.
assert 'grep -qE "apt-get autoremove --purge -y" "$INSTALL_DEPS"' \
       'install_dependencies calls apt-get autoremove --purge -y'
assert 'awk "/log_info .System dependencies installed.$/{end=NR} /apt-get autoremove --purge/{rm=NR} END{exit !(rm<end)}" "$INSTALL_DEPS"' \
       'autoremove runs BEFORE the "System dependencies installed" log marker'

echo
echo "=== Bash syntax ==="
for f in "$DEPLOY" "$SETUP"; do
    if bash -n "$f"; then
        echo "  PASS: bash -n $(basename "$f")"
        pass=$((pass + 1))
    else
        echo "  FAIL: bash -n $(basename "$f")"
        fail=$((fail + 1))
    fi
done

echo
echo "=== Summary ==="
echo "  Pass: $pass"
echo "  Fail: $fail"

[[ "$fail" -eq 0 ]]
