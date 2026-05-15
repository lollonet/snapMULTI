#!/usr/bin/env bash
# Static + integration tests for the cloud-init meta-data refresh in
# prepare-sd.sh (and its PowerShell mirror).
#
# Why: cloud-init NoCloud treats two boots with the same instance-id as
# the SAME instance and skips per-instance modules (incl. runcmd). When
# a user re-prepares an SD that was previously booted, a stale meta-data
# would make cloud-init skip firstboot — the install would never start.
# prepare-sd.sh must always (re)write meta-data with a fresh instance-id.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PREP_SH="$SCRIPT_DIR/../scripts/prepare-sd.sh"
PREP_PS1="$SCRIPT_DIR/../scripts/prepare-sd.ps1"

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

echo "== prepare-sd.sh: meta-data refresh =="

assert 'grep -qE "^METADATA=\"\\\$BOOT/meta-data\"" "$PREP_SH"' \
       'sh: meta-data path uses $BOOT/meta-data'

assert 'grep -qE "snapmulti-\\\$\\(uuidgen" "$PREP_SH"' \
       'sh: fresh instance-id generated via uuidgen'

assert 'grep -qF "instance-id: \$NEW_INSTANCE_ID" "$PREP_SH"' \
       'sh: meta-data write uses generated instance-id'

assert 'awk "/Refresh cloud-init meta-data/{f=1} f&&/WARNING: meta-data already had/{print; exit}" "$PREP_SH" | grep -qF "WARNING"' \
       'sh: warns when meta-data already had an instance-id'

assert 'grep -qF "[MISSING] meta-data: instance-id not refreshed" "$PREP_SH"' \
       'sh: verify step flags missing instance-id refresh'

echo
echo "== prepare-sd.ps1: meta-data refresh (Windows mirror) =="

assert 'grep -qE "\\\$metadata = Join-Path \\\$Boot .meta-data." "$PREP_PS1"' \
       'ps1: metadata path uses Join-Path $Boot meta-data'

assert 'grep -qE "snapmulti-\\\$\\(\\[guid\\]::NewGuid\\(\\)" "$PREP_PS1"' \
       'ps1: fresh instance-id generated via [guid]::NewGuid()'

assert 'grep -qF "WARNING: meta-data already had instance-id=" "$PREP_PS1"' \
       'ps1: warns when meta-data already had an instance-id'

assert 'grep -qF "[MISSING] meta-data: instance-id not refreshed" "$PREP_PS1"' \
       'ps1: verify step flags missing instance-id refresh'

echo
echo "== Integration: actually run the snippet against a fake SD =="

# Replay the sh snippet against a temp dir to prove:
#  - meta-data is created when absent
#  - instance-id has the snapmulti- prefix and is unique across runs
#  - existing meta-data is overwritten (and we observe the warning)
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
BOOT="$TMP"
USERDATA="$BOOT/user-data"
echo 'runcmd: []' > "$USERDATA"

# Run #1: fresh SD, no meta-data yet
run_snippet() {
    local boot="$1" userdata="$2"
    BOOT="$boot" USERDATA="$userdata" bash -c '
        METADATA="$BOOT/meta-data"
        if [[ -f "$USERDATA" ]]; then
            if command -v uuidgen >/dev/null 2>&1; then
                NEW_INSTANCE_ID="snapmulti-$(uuidgen | tr "A-Z" "a-z")"
            else
                NEW_INSTANCE_ID="snapmulti-$(date -u +%Y%m%dT%H%M%SZ)-$$-$RANDOM"
            fi
            warned=0
            if [[ -f "$METADATA" ]]; then
                OLD_ID=$(awk -F": *" "/^instance-id:/ {print \$2; exit}" "$METADATA" 2>/dev/null || true)
                if [[ -n "${OLD_ID:-}" ]]; then
                    warned=1
                    echo "WARNED:${OLD_ID}"
                fi
            fi
            printf "instance-id: %s\n# regenerated\n" "$NEW_INSTANCE_ID" > "$METADATA"
            echo "WROTE:${NEW_INSTANCE_ID}:warned=${warned}"
        fi
    '
}

out1=$(run_snippet "$BOOT" "$USERDATA")
id1=$(echo "$out1" | sed -n 's/^WROTE:\(.*\):warned=.*/\1/p')
assert '[[ -f "$BOOT/meta-data" ]]' \
       'integration: meta-data created on first run'
assert '[[ "$id1" == snapmulti-* ]]' \
       "integration: instance-id has snapmulti- prefix (got '$id1')"
assert 'echo "$out1" | grep -qF "warned=0"' \
       'integration: first run does not emit stale-id warning'

# Run #2: meta-data already present from run #1
out2=$(run_snippet "$BOOT" "$USERDATA")
id2=$(echo "$out2" | sed -n 's/^WROTE:\(.*\):warned=.*/\1/p')
assert 'echo "$out2" | grep -qF "warned=1"' \
       'integration: second run emits stale-id warning'
assert '[[ "$id1" != "$id2" ]]' \
       'integration: second run picks a different instance-id'
assert 'grep -qE "^instance-id: snapmulti-" "$BOOT/meta-data"' \
       'integration: final meta-data has fresh snapmulti- instance-id'

echo
if [[ "$fail" -gt 0 ]]; then
    echo "FAILED: $fail tests failed, $pass passed"
    exit 1
fi
echo "All $pass tests passed!"
