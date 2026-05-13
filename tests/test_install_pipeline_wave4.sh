#!/usr/bin/env bash
# Static checks for Wave-4 install-pipeline fixes:
#   N1/N4 — scrub_credentials runs AFTER setup_music_source has persisted
#           the creds to systemd .mount units on ext4, and BEFORE the
#           deploy.sh invocation that could fail and leave install.conf
#           plaintext on FAT32. A "music" checkpoint guards setup_music_source
#           on retry so empty install.conf vars never reach it.
#   A1   — MPD_START_PERIOD decided from MUSIC_SOURCE (authoritative at
#           install time), not from the runtime is_network_mount probe
#           which returns false when NFS is mid-mount.
#   A3   — When the user picks usb-audio MANUALLY, setup.sh probes
#           aplay -l for the actual ALSA card id (matches the auto path).
#   N3   — setup.sh skips install_dependencies when PROGRESS_MANAGED=1
#           AND essential client commands are present.
#   N5   — firstboot dumps full subprocess tail on deploy/setup failure.
#   N10  — FAILED_MARKER write is atomic (.tmp + sync + mv), no zero-byte.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC2034  # used inside eval'd assert strings
FIRSTBOOT="$SCRIPT_DIR/../scripts/firstboot.sh"
# shellcheck disable=SC2034
DEPLOY_SH="$SCRIPT_DIR/../scripts/deploy.sh"
# shellcheck disable=SC2034
SETUP_SH="$SCRIPT_DIR/../client/common/scripts/setup.sh"

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

echo "=== Wave-4: N1/N4 scrub_credentials timing ==="

# scrub_credentials must come AFTER setup_music_source (creds persisted to
# systemd .mount units on ext4) and BEFORE `bash scripts/deploy.sh` (so a
# deploy failure cannot leave creds plaintext on FAT32 indefinitely).
scrub_line=$(grep -n "^[[:space:]]*scrub_credentials$" "$FIRSTBOOT" | head -1 | cut -d: -f1)
music_line=$(grep -n 'checkpoint_done "music"' "$FIRSTBOOT" | head -1 | cut -d: -f1)
deploy_invoke_line=$(grep -n 'bash scripts/deploy.sh' "$FIRSTBOOT" | head -1 | cut -d: -f1)
if [[ -n "$scrub_line" && -n "$music_line" && -n "$deploy_invoke_line" \
      && "$scrub_line" -gt "$music_line" && "$scrub_line" -lt "$deploy_invoke_line" ]]; then
    echo "  PASS: scrub_credentials runs between music checkpoint ($music_line) and deploy invocation ($deploy_invoke_line) at line $scrub_line"
    pass=$((pass + 1))
else
    echo "  FAIL: scrub_credentials position wrong (scrub=$scrub_line, music=$music_line, deploy=$deploy_invoke_line)"
    fail=$((fail + 1))
fi

# scrub must NOT be inside the if/else guarded by checkpoint_reached "music".
# Otherwise a crash after checkpoint_done but before scrub would skip the
# else branch on retry and leave creds plaintext forever.
assert '! awk "/if checkpoint_reached \"music\"/,/^[[:space:]]*fi\$/" "$FIRSTBOOT" | grep -q "scrub_credentials"' \
       "scrub_credentials sits OUTSIDE the music checkpoint if/else (retry-safe)"

echo
echo "=== Wave-4: A1 MPD_START_PERIOD authoritative source ==="

# The MPD start period decision must look at music_source_value, not
# at is_network_mount of the live mount.
period_block=$(awk '/local mpd_start_period/,/local music_source_value=|^$/' "$DEPLOY_SH" | head -30)
if echo "$period_block" | grep -qE 'case[[:space:]]+"\$music_source_value"'; then
    echo "  PASS: mpd_start_period is gated on music_source_value (case)"
    pass=$((pass + 1))
else
    echo "  FAIL: mpd_start_period still uses is_network_mount runtime probe"
    fail=$((fail + 1))
fi

assert 'grep -q "Network-backed library" "$DEPLOY_SH"' \
       "300s start period log message references the source value"

# Sanity: the case must include nfs/smb/network branches
assert 'grep -qE "nfs\\|smb\\|network" "$DEPLOY_SH"' \
       "case branches cover nfs|smb|network"

echo
echo "=== Wave-4: A3 USB probe in manual select path ==="

# When HAT_CONFIG=usb-audio AND USB_CARD_ID empty, setup.sh probes aplay -l.
assert 'grep -q "manual select path" "$SETUP_SH"' \
       "setup.sh has the manual-select probe path"
assert 'grep -B 5 "Probed USB ALSA card id" "$SETUP_SH" | grep -q "USB_CARD_ID:-"' \
       "manual probe is gated on USB_CARD_ID being empty"

echo
echo "=== Wave-4: N3 PROGRESS_MANAGED skip on essential commands ==="

assert 'grep -q "_essential_client_cmds_present" "$SETUP_SH"' \
       "setup.sh defines _essential_client_cmds_present"
assert 'grep -A 3 "_essential_client_cmds_present()" "$SETUP_SH" | grep -q "command -v aplay"' \
       "essential check covers aplay (alsa-utils)"
assert 'grep -A 3 "_essential_client_cmds_present()" "$SETUP_SH" | grep -q "command -v avahi-daemon"' \
       "essential check covers avahi-daemon"
assert 'grep -qE "PROGRESS_MANAGED.*_essential_client_cmds_present" "$SETUP_SH"' \
       "skip is gated on BOTH PROGRESS_MANAGED AND essentials present"

echo
echo "=== Wave-4: N5 failure-path subprocess dump ==="

assert 'grep -q "deploy_log=\$(mktemp" "$FIRSTBOOT"' \
       "deploy subprocess output is teed to a temp file"
assert 'grep -q "setup_log=\$(mktemp" "$FIRSTBOOT"' \
       "setup subprocess output is teed to a temp file"
assert 'grep -q "Full subprocess output (last 200 lines)" "$FIRSTBOOT"' \
       "failure path dumps the captured tail"
assert 'grep -qE "tail -n 200 \"\\\$(deploy|setup)_log\"" "$FIRSTBOOT"' \
       "tail uses the captured log file"

echo
echo "=== Wave-4: N10 atomic FAILED_MARKER ==="

assert '! grep -qE "^[[:space:]]+touch \"\\\$FAILED_MARKER\"" "$FIRSTBOOT"' \
       "no bare touch of FAILED_MARKER"
assert 'grep -q "FAILED_MARKER}.tmp" "$FIRSTBOOT"' \
       "FAILED_MARKER is written via .tmp + sync + mv"
assert 'grep -A 3 "FAILED_MARKER}.tmp" "$FIRSTBOOT" | grep -q "sync --"' \
       "sync is called before mv"

echo
if (( fail > 0 )); then
    echo "FAILED: $fail / $((pass + fail))"
    exit 1
fi
echo "All $pass tests passed!"
