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

# Strip CR: .gitattributes checks *.ps1 out with CRLF line endings.
content="$(tr -d '\r' < "$PS1_FILE")"
PREP_SH="$SCRIPT_DIR/../scripts/prepare-sd.sh"
REPO_ROOT="$SCRIPT_DIR/.."

assert_true() {
    local desc="$1"; shift
    if "$@"; then
        echo "  PASS: $desc"
        pass=$((pass + 1))
    else
        echo "  FAIL: $desc"
        fail=$((fail + 1))
    fi
}

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
    pass=$((pass+1)); echo "PASS: install.conf does NOT emit SNAPMULTI_RELEASE (SSOT is release-manifest.json)"
fi
if grep -qE '^\s*SNAPMULTI_IMAGE_SET=\$ManifestImageSet' <<<"$content"; then
    fail=$((fail+1)); echo "FAIL: install.conf must NOT emit SNAPMULTI_IMAGE_SET (SSOT is release-manifest.json)"
else
    pass=$((pass+1)); echo "PASS: install.conf does NOT emit SNAPMULTI_IMAGE_SET (SSOT is release-manifest.json)"
fi
assert_contains "$content" "Copy-Item \$ManifestPath -Destination \$Dest" \
    "release-manifest.json staged to SD destination"
assert_contains "$content" "'release-manifest.json'" \
    "release-manifest.json appears in verifyrequiredBase list"
assert_contains "$content" "'common/release-manifest.sh'" \
    "common/release-manifest.sh appears in verifyrequiredBase list"

# -- Windows PowerShell 5.1 compatibility (#Requires -Version 5.1) ---------
# PS 5.1 reads a BOM-less script as cp1252: the UTF-8 em-dash byte 0x94
# becomes U+201D, which the parser treats as a closing quote. Any
# non-ASCII byte is therefore a latent parse error on stock Windows.
assert_true "prepare-sd.ps1 is pure ASCII (PS 5.1 reads BOM-less files as cp1252)" \
    bash -c "! LC_ALL=C grep -qP '[^\x00-\x7F]' '$PS1_FILE'"
# Join-Path with more than one child path is PowerShell 6+ only.
assert_true "no multi-child Join-Path (PowerShell 6+ only)" \
    bash -c "! grep -qE \"Join-Path +[^ ()|]+ +'[^']*' +'\" '$PS1_FILE'"
for construct in ' ?? ' '-AsHashtable' '-AdditionalChildPath' '-AsByteStream' 'utf8NoBOM' 'ForEach-Object -Parallel'; do
    if grep -qF -- "$construct" <<<"$content"; then
        echo "  FAIL: PS 6+/7-only construct found: '$construct'"
        fail=$((fail + 1))
    else
        echo "  PASS: no PS 6+/7-only construct '$construct'"
        pass=$((pass + 1))
    fi
done

# -- Line endings / BOM on staged files ------------------------------------
assert_contains "$content" 'function Convert-StagedTextToLf' "CRLF->LF normaliser for staged files exists"
assert_contains "$content" 'Convert-StagedTextToLf -Root $Dest' "staged files are normalised to LF"
assert_contains "$content" '$confContent = $confContent.Replace("`r`n", "`n")' "install.conf here-string written with LF"
norm_line=$(grep -nF 'Convert-StagedTextToLf -Root $Dest' <<<"$content" | head -1 | cut -d: -f1 || true)
copy_line=$(grep -nF "'both'   { Copy-ServerFiles -Dest \$Dest; Copy-ClientFiles -Dest \$Dest }" <<<"$content" | head -1 | cut -d: -f1 || true)
assert_true "normalisation runs after the mode-specific copies" \
    test -n "$norm_line" -a -n "$copy_line" -a "${norm_line:-0}" -gt "${copy_line:-0}"
attrs="$REPO_ROOT/.gitattributes"
assert_true ".gitattributes exists" test -f "$attrs"
for rule in '*.sh        text eol=lf' '*.py        text eol=lf' '*.service   text eol=lf' '*.ps1 text eol=crlf' '*.wav  binary'; do
    if grep -qF -- "$rule" "$attrs" 2>/dev/null; then
        echo "  PASS: .gitattributes has '$rule'"
        pass=$((pass + 1))
    else
        echo "  FAIL: .gitattributes missing '$rule'"
        fail=$((fail + 1))
    fi
done

# -- user-data patch: indentation-aware, validated before write, on rerun ---
assert_contains "$content" 'function Test-UserDataRuncmd' "user-data validator exists"
validate_calls=$(grep -cF 'Test-UserDataRuncmd -Content' <<<"$content" || true)
assert_true "user-data validated on both the patch and the already-patched paths" \
    test "${validate_calls:-0}" -ge 2
assert_true "no user-data backup copy (it would duplicate credentials)" \
    bash -c '! grep -qF "snapmulti.bak" "$1"' _ "$PS1_FILE"
val_line=$(grep -nF 'Test-UserDataRuncmd -Content $patched' <<<"$content" | head -1 | cut -d: -f1 || true)
write_line=$(grep -nF 'Move-Item -Path $userDataTmp -Destination $userData -Force' <<<"$content" | head -1 | cut -d: -f1 || true)
assert_true "patched user-data validated before it replaces the original" \
    test -n "$val_line" -a -n "$write_line" -a "${val_line:-0}" -lt "${write_line:-0}"
assert_contains "$content" '$child = $Matches[1]' "runcmd entry inherits the existing item indent"

# -- cmdline.txt swap/zram masks: parity with prepare-sd.sh SWAP_MASK_UNITS -
sh_units=$(sed -n '/^    SWAP_MASK_UNITS=(/,/^    )/p' "$PREP_SH" | grep -oE '[A-Za-z0-9@.-]+\.(service|swap|timer)' | sort)
ps_units=$(sed -n '/^    \$swapMaskUnits = @(/,/^    )/p' <<<"$content" | grep -oE "'[A-Za-z0-9@.-]+'" | tr -d "'" | sort)
assert_true "ps1 masks the same swap/zram units as prepare-sd.sh" \
    test -n "$sh_units" -a "$sh_units" = "$ps_units"
assert_contains "$content" 'foreach ($unit in ($swapMaskUnits + $bootMaskUnits))' "swap masks are written to cmdline.txt"

# -- verify lists: parity with prepare-sd.sh ---------------------------------
sh_list() { sed -n "/^    for f in $1\\/docker-compose.yml/,/; do\$/p" "$PREP_SH" | grep -oE "$1/[A-Za-z0-9_./-]+" | sort -u; }
ps_list() { sed -n "/^            '$1\\/docker-compose.yml',/,/^        )) {/p" <<<"$content" | grep -v '^\s*#' | grep -oE "$1/[A-Za-z0-9_./-]+" | sort -u; }
for mode in server client; do
    a=$(sh_list "$mode"); b=$(ps_list "$mode")
    if [[ -n "$a" && "$a" == "$b" ]]; then
        echo "  PASS: $mode verify list identical in prepare-sd.sh and prepare-sd.ps1"
        pass=$((pass + 1))
    else
        echo "  FAIL: $mode verify list differs:"
        diff <(echo "$a") <(echo "$b") | sed 's/^/        /' || true
        fail=$((fail + 1))
    fi
done
sh_base=$(sed -n '/^for f in install.conf/,/; do$/p' "$PREP_SH" | grep -oE '(common/[A-Za-z0-9_./-]+|install\.conf|firstboot\.sh|release-manifest\.json)' | sort -u)
ps_base=$(sed -n '/^    \$requiredBase = @(/,/^    )/p' <<<"$content" | grep -v '^\s*#' | grep -oE "'[^']+'" | tr -d "'" | sort -u)
if [[ -n "$sh_base" && "$sh_base" == "$ps_base" ]]; then
    echo "  PASS: base verify list identical in prepare-sd.sh and prepare-sd.ps1"
    pass=$((pass + 1))
else
    echo "  FAIL: base verify list differs:"
    diff <(echo "$sh_base") <(echo "$ps_base") | sed 's/^/        /' || true
    fail=$((fail + 1))
fi

# -- Next steps print the known hostname ------------------------------------
assert_contains "$content" "Pattern '^hostname:\\s*(\\S+)'" "hostname read from user-data for Next steps"

echo ""
if [[ "$fail" -gt 0 ]]; then
    echo "FAILED: $fail tests failed, $pass passed"
    exit 1
fi
echo "All $pass tests passed!"
