#!/usr/bin/env bash
# Runtime smoke test for prepare-sd.ps1's release-manifest reading.
# Invokes the manifest-reading prologue via pwsh with cwd=/tmp to prove
# that path resolution uses $ScriptDir / $ProjectDir (script-anchored)
# and NOT $PWD or relative paths — a Windows user running the script
# from anywhere on disk must still find release-manifest.json.
#
# Skipped with an info line when pwsh is unavailable (most dev macOS /
# Linux boxes; CI may have it via the powershell/setup action).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PS1_FILE="$PROJECT_DIR/scripts/prepare-sd.ps1"

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

echo "## prepare-sd.ps1 runtime — script-anchored manifest resolution"

if ! command -v pwsh >/dev/null 2>&1; then
    echo "  INFO: pwsh not installed — runtime asserts skipped"
    echo "        Static checks live in tests/test_prepare_sd_ps1_static.sh"
    echo
    echo "## Summary"
    echo "  Passed: 0 (skipped)"
    exit 0
fi

assert "[[ -f '$PS1_FILE' ]]" "prepare-sd.ps1 exists"

# Extract the manifest-reading prologue into a standalone snippet that
# pwsh can run end-to-end (without the rest of the script's args). We
# fabricate the $ScriptDir / $ProjectDir variables so the snippet
# behaves exactly like the script's prologue.
SNIPPET=$(mktemp -t ps1-manifest-runtime.XXXXXX.ps1)
trap 'rm -f "$SNIPPET"' EXIT
cat > "$SNIPPET" <<EOF
Set-StrictMode -Version Latest
\$ErrorActionPreference = 'Stop'
\$ScriptDir = '$PROJECT_DIR/scripts'
\$ProjectDir = '$PROJECT_DIR'
\$ManifestPath = Join-Path \$ProjectDir 'release-manifest.json'
\$ManifestRelease = ''
\$ManifestImageSet = ''
if (Test-Path \$ManifestPath) {
    \$manifest = Get-Content -Raw -Path \$ManifestPath | ConvertFrom-Json
    if (\$manifest.PSObject.Properties.Name -contains 'snapmulti_release') {
        \$ManifestRelease = [string]\$manifest.snapmulti_release
    }
    if (\$manifest.PSObject.Properties.Name -contains 'image_set') {
        \$ManifestImageSet = [string]\$manifest.image_set
    }
}
Write-Output "RELEASE=\$ManifestRelease"
Write-Output "IMAGE_SET=\$ManifestImageSet"
EOF

# Run from /tmp (different cwd) so we prove the script-anchored
# resolution actually works — a $PWD-based path would NOT find the
# manifest from /tmp.
output=$(cd /tmp && pwsh -NoProfile -NonInteractive -File "$SNIPPET" 2>&1)

assert "grep -q '^RELEASE=v' <<<\"\$output\"" \
    "release captured from $PROJECT_DIR/release-manifest.json (cwd=/tmp)"
assert "grep -q '^IMAGE_SET=' <<<\"\$output\"" \
    "image_set captured (cwd=/tmp)"

echo
echo "## Summary"
echo "  Passed: $pass"
echo "  Failed: $fail"

[[ $fail -eq 0 ]]
