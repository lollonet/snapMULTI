#!/usr/bin/env bash
# Static checks for Wave-2 install-pipeline fixes:
#   - deploy.sh adds network MUSIC_PATH to RequiresMountsFor
#   - setup.sh has the fail-hard fuse-overlayfs switch (with checkpoint
#     guard so firstboot's existing checkpoint is honoured)
#   - setup.sh installs HAT detection deps before detect_hat
#   - snapclient Dockerfile pulls libasound2-plugins so the ALSA
#     rate_converter samplerate_best path resolves at runtime

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_SH="$SCRIPT_DIR/../scripts/deploy.sh"
SETUP_SH="$SCRIPT_DIR/../client/common/scripts/setup.sh"
SNAPCLIENT_DOCKERFILE="$SCRIPT_DIR/../client/common/docker/snapclient/Dockerfile"

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

echo "=== Wave-2: deploy.sh RequiresMountsFor music_path ==="

assert 'grep -q "music_mount_clause" "$DEPLOY_SH"' \
       "deploy.sh defines music_mount_clause variable"

assert 'grep -q "music_source_from_env" "$DEPLOY_SH"' \
       "deploy.sh reads MUSIC_SOURCE from .env (authoritative at install time)"

assert 'grep -qE "nfs\\|smb\\|network" "$DEPLOY_SH"' \
       "MUSIC_SOURCE in {nfs,smb,network} adds path to RequiresMountsFor"

assert 'grep -q "is_network_mount \"\$music_path_from_env\"" "$DEPLOY_SH"' \
       "is_network_mount runtime probe kept as fallback for manual deploys"

assert 'grep -qE "RequiresMountsFor=.*\\\${PROJECT_ROOT}/audio\\\${music_mount_clause}" "$DEPLOY_SH"' \
       "RequiresMountsFor heredoc embeds music_mount_clause"

# The MUSIC_PATH read must happen before the heredoc that expands it
mount_var_line=$(grep -n "music_path_from_env=\"" "$DEPLOY_SH" | head -1 | cut -d: -f1)
heredoc_line=$(grep -n "RequiresMountsFor=.*music_mount_clause" "$DEPLOY_SH" | head -1 | cut -d: -f1)
if [[ -n "$mount_var_line" && -n "$heredoc_line" && "$mount_var_line" -lt "$heredoc_line" ]]; then
    echo "  PASS: music_path resolved before unit heredoc (line $mount_var_line < $heredoc_line)"
    pass=$((pass + 1))
else
    echo "  FAIL: music_path resolution must come BEFORE the heredoc"
    fail=$((fail + 1))
fi

echo
echo "=== Wave-2: setup.sh fail-hard fuse-overlayfs switch ==="

assert 'grep -q "Fail-hard pre-pull guard" "$SETUP_SH"' \
       "setup.sh has fail-hard pre-pull comment"

assert 'grep -q "_switch_checkpoint=\"/var/lib/snapmulti-installer/.done-fuse-overlayfs-switched\"" "$SETUP_SH"' \
       "setup.sh references firstboot checkpoint file (idempotent guard)"

assert 'grep -q "rm -rf /var/lib/docker/\\*" "$SETUP_SH"' \
       "setup.sh wipes overlay2 layers before restart"

assert 'grep -qE "exit 1$" "$SETUP_SH"' \
       "setup.sh exits non-zero on failed switch (fail-hard)"

assert 'grep -qE "fuse-overlayfs not active after restart" "$SETUP_SH"' \
       "setup.sh logs the specific failure mode"

# The switch block must run before the pull (progress 10)
switch_line=$(grep -n "Forcing Docker storage driver" "$SETUP_SH" | head -1 | cut -d: -f1)
pull_line=$(grep -n "^progress 10 \"Pulling container images" "$SETUP_SH" | head -1 | cut -d: -f1)
if [[ -n "$switch_line" && -n "$pull_line" && "$switch_line" -lt "$pull_line" ]]; then
    echo "  PASS: fail-hard switch precedes the pull (line $switch_line < $pull_line)"
    pass=$((pass + 1))
else
    echo "  FAIL: fail-hard switch must come BEFORE 'Pulling container images'"
    fail=$((fail + 1))
fi

echo
echo "=== Wave-2: setup.sh HAT detection deps before detect_hat ==="

assert 'grep -q "_ensure_hat_detect_tools" "$SETUP_SH"' \
       "setup.sh defines _ensure_hat_detect_tools"

assert 'grep -q "command -v aplay" "$SETUP_SH"' \
       "checks for aplay (alsa-utils)"

assert 'grep -q "command -v i2cdetect" "$SETUP_SH"' \
       "checks for i2cdetect (i2c-tools)"

# Tools install must precede first detect_hat call (line of `_ensure_hat_detect_tools`
# call must come before the `detect_hat > "$_hat_tmp"` line)
ensure_line=$(grep -n "^_ensure_hat_detect_tools$" "$SETUP_SH" | head -1 | cut -d: -f1)
detect_line=$(grep -n 'detect_hat > "\$_hat_tmp"' "$SETUP_SH" | head -1 | cut -d: -f1)
if [[ -n "$ensure_line" && -n "$detect_line" && "$ensure_line" -lt "$detect_line" ]]; then
    echo "  PASS: ensure_hat_detect_tools precedes detect_hat (line $ensure_line < $detect_line)"
    pass=$((pass + 1))
else
    echo "  FAIL: dep install must come BEFORE detect_hat (ensure=$ensure_line, detect=$detect_line)"
    fail=$((fail + 1))
fi

echo
echo "=== Wave-2: snapclient Dockerfile libasound2-plugins ==="

assert 'grep -qE "^\\s*libasound2-plugins" "$SNAPCLIENT_DOCKERFILE"' \
       "Dockerfile installs libasound2-plugins (rate_converter samplerate_best)"

# Must be in the runtime image, not the builder stage. Find the second
# (runtime) FROM line and ensure libasound2-plugins appears AFTER it.
runtime_from_line=$(grep -nE "^FROM " "$SNAPCLIENT_DOCKERFILE" | tail -1 | cut -d: -f1)
plugins_line=$(grep -nE "^\s*libasound2-plugins" "$SNAPCLIENT_DOCKERFILE" | head -1 | cut -d: -f1)
if [[ -n "$runtime_from_line" && -n "$plugins_line" && "$plugins_line" -gt "$runtime_from_line" ]]; then
    echo "  PASS: libasound2-plugins in runtime stage (line $plugins_line > FROM line $runtime_from_line)"
    pass=$((pass + 1))
else
    echo "  FAIL: libasound2-plugins must be in the runtime stage, not builder"
    fail=$((fail + 1))
fi

echo
if (( fail > 0 )); then
    echo "FAILED: $fail / $((pass + fail))"
    exit 1
fi
echo "All $pass tests passed!"
