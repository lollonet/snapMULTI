#!/usr/bin/env bash
# Static + invocation checks for client/common/scripts/setup-zero2w.sh.
#
# What this test guarantees:
#   1. Script exists, executable, shellcheck-clean, bash-syntax-valid.
#   2. snapclient install uses distro apt (Trixie 0.31, Bookworm 0.27)
#      — not the badaix .deb release (Bookworm-only, fails on Trixie).
#   3. The systemd drop-in path uses the canonical .service.d/ pattern
#      and declares restart limits.
#   4. The script exits non-zero on snapclient install failure so
#      firstboot.sh's retry-on-next-boot pattern fires.
#   5. --help invocation returns 0 (script is callable without root).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SETUP="$SCRIPT_DIR/../client/common/scripts/setup-zero2w.sh"

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

echo "== client/common/scripts/setup-zero2w.sh =="

# 1. File present + executable + syntactic
assert "[[ -f \"$SETUP\" ]]" "file present"
assert "[[ -x \"$SETUP\" ]]" "file executable"
assert "bash -n \"$SETUP\"" "bash -n passes"
if command -v shellcheck >/dev/null 2>&1; then
    assert "shellcheck \"$SETUP\"" "shellcheck clean"
fi
assert 'grep -qE "^set -euo pipefail" "$SETUP"' \
    "uses set -euo pipefail"

# 2. snapclient install source: distro apt, not badaix .deb URL
assert 'grep -qE "apt-get install .* snapclient" "$SETUP"' \
    "installs snapclient from distro apt"
assert '! grep -qE "github\\.com/badaix/snapcast/releases" "$SETUP"' \
    "no badaix .deb URL (would fail on Trixie — libflac12 unresolvable)"
assert '! grep -qE "^[[:space:]]*sha256sum |^SNAPCLIENT_SHA256_" "$SETUP"' \
    "no SHA256 pinning (apt handles signatures)"

# 3. Pre-install version-installed short-circuit
assert 'grep -qF "dpkg-query -W -f" "$SETUP"' \
    "idempotent: short-circuits when snapclient package already installed"

# 4. systemd drop-in path canonical + restart limits present
assert 'grep -qF "/etc/systemd/system/snapclient.service.d" "$SETUP"' \
    "drop-in path uses /etc/systemd/system/snapclient.service.d/"
for k in "StartLimitBurst=5" "StartLimitIntervalSec=300" "Restart=on-failure"; do
    assert "grep -qF \"$k\" \"$SETUP\"" \
        "drop-in declares $k"
done

# 5. Exit 1 on install failure (firstboot retry trigger)
assert 'grep -qF "firstboot will retry on next boot" "$SETUP"' \
    "logs firstboot-retry intent on install failure"
exit_lines=$(grep -cE "^[[:space:]]+exit 1" "$SETUP" || true)
assert "[[ \"$exit_lines\" -ge 1 ]]" \
    "has >= 1 'exit 1' bailout site — got $exit_lines"

# 6. --help works without root + does not invoke apt
help_out=$(bash "$SETUP" --help 2>&1 || true)
assert 'echo "$help_out" | grep -qi "usage"' \
    "--help prints usage and exits 0"
assert '[[ "$help_out" != *"apt-get install -y --no-install-recommends snapclient"* ]]' \
    "--help path does not invoke apt-get install snapclient"

# 7. Audio HAT detection wiring
assert 'grep -qE "command -v detect_hat" "$SETUP"' \
    "calls detect_hat (not the nonexistent detect_audio_hat)"
assert 'grep -qE "resolve_hat_config_name" "$SETUP"' \
    "normalises HAT_CONFIG via resolve_hat_config_name"
assert 'grep -qF "audio-hats" "$SETUP"' \
    "loads HAT_CARD_NAME / HAT_OVERLAY from audio-hats/*.conf"

# 7a. detect_hat must NOT be called in $(...) command substitution.
# Subshell scope discards HAT_DETECTION_SOURCE side-effect, so the
# downstream log reads "source: none" even on a successful detection.
# Use tempfile capture (same pattern as setup.sh:279-285) to preserve
# the global. Observed live on pizero before this fix.
assert '! grep -qE "_hat_config=\\\$\\(detect_hat" "$SETUP"' \
    "detect_hat NOT called in command substitution (would lose HAT_DETECTION_SOURCE)"
assert 'grep -qE "mktemp.*snapclient-hat" "$SETUP"' \
    "detect_hat output captured via mktemp tempfile (preserves global side-effects)"

# 8. config.txt write: dtoverlay line must have NO inline comment
#    (bootloader treats anything after `=` as part of the value).
assert 'awk '\''/echo "dtoverlay=\$HAT_OVERLAY"/'\'' "$SETUP" | grep -vqE "#"' \
    "dtoverlay line emitted to config.txt has no trailing inline comment"
assert 'grep -qF "dtparam=i2s=on" "$SETUP"' \
    "config.txt block enables I2S bus (dtparam=i2s=on)"
assert 'grep -qF "dtparam=audio=off" "$SETUP"' \
    "config.txt block disables on-board HDMI audio (dtparam=audio=off)"
assert 'grep -qE "SNAPCLIENT ZERO2W AUDIO HAT START" "$SETUP"' \
    "config.txt edits are wrapped in a marker block (idempotent)"
assert 'grep -qE "sed -i .s/\\^dtparam=audio=on/" "$SETUP"' \
    "factory dtparam=audio=on is commented out before adding audio=off"
assert 'grep -qE "grep -qE .\\^dtparam=audio=on. \"\\\$BOOT_CONFIG\"" "$SETUP"' \
    "comment-out is guarded by grep for idempotency on re-run"

# 9. /etc/asound.conf write referencing HAT_CARD_NAME
assert 'grep -qE "/etc/asound\\.conf" "$SETUP"' \
    "writes /etc/asound.conf"
assert 'grep -qE "hw:CARD=\\\$HAT_CARD_NAME" "$SETUP"' \
    "asound.conf slave.pcm points to hw:CARD=\$HAT_CARD_NAME"

echo
echo "Results: $pass passed, $fail failed"
exit $(( fail > 0 ? 1 : 0 ))
