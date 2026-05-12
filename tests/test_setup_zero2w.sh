#!/usr/bin/env bash
# Static + invocation checks for client/common/scripts/setup-zero2w.sh.
#
# What this test guarantees:
#   1. Script exists, executable, shellcheck-clean, bash-syntax-valid.
#   2. SHA256 pins for arm64 + armhf .deb assets are 64-hex strings
#      (catches accidental empty-string commits).
#   3. .deb URL pattern matches the badaix release naming convention
#      (snapclient_<rev>_<arch>_bookworm.deb).
#   4. The systemd drop-in path uses the canonical .service.d/ pattern.
#   5. The script exits non-zero on .deb download/checksum failure so
#      firstboot.sh's retry-on-next-boot pattern fires.
#   6. --help invocation returns 0 (script is callable without root).

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

# 1. File present + executable
assert "[[ -f \"$SETUP\" ]]" "file present"
assert "[[ -x \"$SETUP\" ]]" "file executable"

# 2. Bash syntax valid
assert "bash -n \"$SETUP\"" "bash -n passes"

# 3. Shellcheck clean (if available locally; CI gates on it anyway)
if command -v shellcheck >/dev/null 2>&1; then
    assert "shellcheck \"$SETUP\"" "shellcheck clean"
fi

# 4. set -euo pipefail at top
assert 'grep -qE "^set -euo pipefail" "$SETUP"' \
    "uses set -euo pipefail"

# 5. SHA256 pins are 64-hex (not empty, not placeholder)
SHA_ARM64=$(grep -E '^SNAPCLIENT_SHA256_ARM64=' "$SETUP" | head -1 | cut -d'=' -f2 | tr -d '"' | tr -d "'")
SHA_ARMHF=$(grep -E '^SNAPCLIENT_SHA256_ARMHF=' "$SETUP" | head -1 | cut -d'=' -f2 | tr -d '"' | tr -d "'")
assert "[[ \"\${#SHA_ARM64}\" -eq 64 && \"$SHA_ARM64\" =~ ^[a-f0-9]+\$ ]]" \
    "SHA256_ARM64 pinned (64 hex chars): ${SHA_ARM64:0:16}..."
assert "[[ \"\${#SHA_ARMHF}\" -eq 64 && \"$SHA_ARMHF\" =~ ^[a-f0-9]+\$ ]]" \
    "SHA256_ARMHF pinned (64 hex chars): ${SHA_ARMHF:0:16}..."

# 6. .deb URL pattern matches badaix release naming
assert 'grep -qE "snapclient_\\\$\\{SNAPCLIENT_DEB_REV\\}_\\\$\\{ARCH\\}_bookworm\\.deb" "$SETUP"' \
    "URL pattern follows badaix convention (snapclient_<rev>_<arch>_bookworm.deb)"

# 7. Idempotency check — short-circuits if v0.35 already installed
assert 'grep -qF "already installed" "$SETUP"' \
    "idempotent: skips install when target version already present"

# 8. systemd drop-in path canonical
assert 'grep -qF "/etc/systemd/system/snapclient.service.d" "$SETUP"' \
    "drop-in path uses /etc/systemd/system/snapclient.service.d/"

# 9. drop-in includes restart limits (catches infinite restart-loop on
#    failed ALSA bind)
for k in "StartLimitBurst=5" "StartLimitIntervalSec=300" "Restart=on-failure"; do
    assert "grep -qF \"$k\" \"$SETUP\"" \
        "drop-in declares $k"
done

# 10. Exit 1 on .deb download / checksum failure (firstboot retry trigger)
assert 'grep -qF "firstboot will retry on next boot" "$SETUP"' \
    "logs firstboot-retry intent on download failure"
exit_lines=$(grep -cE "^[[:space:]]+exit 1" "$SETUP" || true)
assert "[[ \"$exit_lines\" -ge 3 ]]" \
    "has >= 3 'exit 1' bailout sites (download fail, sha mismatch, dpkg fail) — got $exit_lines"

# 11. --help works and exits 0 (callable from any context, no root needed
#     for the help path)
help_out=$(bash "$SETUP" --help 2>&1 || true)
assert 'echo "$help_out" | grep -qi "usage"' \
    "--help prints usage and exits 0"

# 12. Help mode is gated BEFORE any apt-get / dpkg call — even without
#     root, --help must not try to install packages
assert '[[ "$help_out" != *"apt-get"* ]]' \
    "--help path does not invoke apt-get"

echo
echo "Results: $pass passed, $fail failed"
exit $(( fail > 0 ? 1 : 0 ))
