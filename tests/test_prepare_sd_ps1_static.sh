#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PS1_FILE="$SCRIPT_DIR/../scripts/prepare-sd.ps1"

pass=0
fail=0

assert_contains() {
    local haystack="$1" needle="$2" desc="$3"
    if grep -qF "$needle" <<<"$haystack"; then
        echo "  PASS: $desc"
        pass=$((pass + 1))
    else
        echo "  FAIL: $desc (missing '$needle')"
        fail=$((fail + 1))
    fi
}

content="$(cat "$PS1_FILE")"

echo "Testing prepare-sd.ps1 parity guards..."

assert_contains "$content" 'function Update-UserDataRuncmd' "user-data patch helper exists"
assert_contains "$content" "common/unified-log.sh" "unified-log is verified"
assert_contains "$content" "common/install-deps.sh" "install-deps is verified"
assert_contains "$content" "common/setup-docker.sh" "setup-docker is verified"
assert_contains "$content" "common/wait-network.sh" "wait-network is verified"
assert_contains "$content" "common/mount-music.sh" "mount-music is verified"
assert_contains "$content" "WriteAllText((Join-Path \$Dest 'server/.version'), \$gitVersion, \$Utf8NoBom)" "server version uses UTF-8 without BOM"
assert_contains "$content" "WriteAllText((Join-Path \$Dest 'client/VERSION'), \$gitVersion, \$Utf8NoBom)" "client version uses UTF-8 without BOM"
assert_contains "$content" 'Assert-PreparedSdCard -Dest $Dest -Boot $Boot -InstallType $InstallType' "verification runs before eject"
assert_contains "$content" "runcmd:\\s*(\\[\\]|null|~)?" "inline/empty runcmd cases handled"

# docker/ directory copy (parity with PR #321 on the bash side).
# Without this copy, the metadata-service bind-mount in
# docker-compose.yml (PR #319) breaks the install on Windows-prepped
# SD cards because Docker auto-creates an empty dir at the bind source.
assert_contains "$content" "Join-Path \$ProjectDir 'docker'" "docker/ source path resolved"
assert_contains "$content" 'Test-Path $dockerSrc' "docker/ copy is guarded on the source existing"
assert_contains "$content" "New-Item -ItemType Directory -Path \$dockerDest" "docker/ destination created idempotently"

# Optional helper copies (parity with .sh).
assert_contains "$content" "docker-driver-reconcile.sh" "docker-driver-reconcile.sh copied (optional)"

# install.conf advanced keys (parity with .sh, otherwise firstboot reads
# undefined values for SKIP_UPGRADE / IMAGE_TAG / VERBOSE_INSTALL).
assert_contains "$content" "SKIP_UPGRADE=" "install.conf carries SKIP_UPGRADE"
assert_contains "$content" "IMAGE_TAG=" "install.conf carries IMAGE_TAG"
assert_contains "$content" "VERBOSE_INSTALL=" "install.conf carries VERBOSE_INSTALL"

# Release-manifest wiring (#433). Path resolution MUST use script-anchored
# variables ($ProjectDir / $ScriptDir), never $PWD or bare relative paths,
# so a user running the script from a different cwd still finds the file.
assert_contains "$content" "Join-Path \$ProjectDir 'release-manifest.json'" \
    "release-manifest.json path resolved via \$ProjectDir (script-anchored)"
assert_contains "$content" "Get-Content -Raw -Path \$ManifestPath" \
    "release-manifest.json read with Get-Content -Raw"
assert_contains "$content" "ConvertFrom-Json" \
    "release-manifest.json parsed via ConvertFrom-Json"
if grep -qE '^\s*SNAPMULTI_RELEASE=\$ManifestRelease' <<<"$content"; then
    fail=$((fail+1)); echo "FAIL: install.conf must NOT emit SNAPMULTI_RELEASE (SSOT is release-manifest.json)"
else
    echo "PASS: install.conf does NOT emit SNAPMULTI_RELEASE (SSOT is release-manifest.json)"
fi
if grep -qE '^\s*SNAPMULTI_IMAGE_SET=\$ManifestImageSet' <<<"$content"; then
    fail=$((fail+1)); echo "FAIL: install.conf must NOT emit SNAPMULTI_IMAGE_SET (SSOT is release-manifest.json)"
else
    echo "PASS: install.conf does NOT emit SNAPMULTI_IMAGE_SET (SSOT is release-manifest.json)"
fi
assert_contains "$content" "Copy-Item \$ManifestPath -Destination \$Dest" \
    "release-manifest.json staged to SD destination"
assert_contains "$content" "'release-manifest.json'" \
    "release-manifest.json appears in verifyrequiredBase list"
assert_contains "$content" "'common/release-manifest.sh'" \
    "common/release-manifest.sh appears in verifyrequiredBase list"

echo ""
if [[ "$fail" -gt 0 ]]; then
    echo "FAILED: $fail tests failed, $pass passed"
    exit 1
fi
echo "All $pass tests passed!"
