#!/usr/bin/env bash
# Static checks for Wave-3 install-pipeline fixes:
#   - save-diagnostics.sh uses find (not ls glob) so it survives the
#     first run on an empty $DIAG_DIR (TODAY-B regression)
#   - metadata-service.py /status responses do NOT carry
#     `Access-Control-Allow-Origin: *` — the snapshot is diagnostic
#     data and should not be exfiltrable from arbitrary LAN web pages
#     (#10c). Other endpoints (artwork, /metadata.json, /version, /health)
#     keep their CORS headers since they are intentionally consumable
#     by the snapcast Web UI.
#   - audio-hat-detect.sh probes the actual ALSA card id from `aplay -l`
#     and exports USB_CARD_ID instead of relying on the hardcoded
#     `HAT_CARD_NAME="USB"` from usb-audio.conf (#8).
#   - setup.sh honours USB_CARD_ID when HAT_CONFIG=usb-audio.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SAVE_DIAG="$SCRIPT_DIR/../scripts/common/save-diagnostics.sh"
METADATA_PY="$SCRIPT_DIR/../docker/metadata-service/metadata-service.py"
HAT_DETECT="$SCRIPT_DIR/../client/common/scripts/audio-hat-detect.sh"
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

echo "=== Wave-3: save-diagnostics first-run robustness ==="

assert '! grep -q "ls -1d \"\$DIAG_DIR\"/\\[0-9\\]\\*" "$SAVE_DIAG"' \
       "save-diagnostics no longer uses ls glob (failed exit 2 on empty dir)"
assert 'grep -q "find \"\$DIAG_DIR\"" "$SAVE_DIAG"' \
       "save-diagnostics uses find instead"
assert 'grep -q "|| true" "$SAVE_DIAG"' \
       "rotation pipe ends with || true so set -e doesn't kill on no matches"

echo
echo "=== Wave-3: /status CORS removed (#10c) ==="

# Locate the handle_status function and assert its body does NOT carry
# Access-Control-Allow-Origin headers (the body is bounded by the next
# `async def` definition).
status_block=$(awk '
    /^async def handle_status/ { capture=1 }
    capture { print }
    /^async def / && !/handle_status/ { if (capture) { capture=0; exit } }
' "$METADATA_PY")

if [[ -z "$status_block" ]]; then
    echo "  FAIL: could not locate handle_status block in metadata-service.py"
    fail=$((fail + 1))
else
    # Match the actual dict-syntax header ("Access-Control-Allow-Origin": "*"),
    # not the explanatory mention inside the function docstring.
    if echo "$status_block" | grep -qE '"Access-Control-Allow-Origin"\s*:\s*"\*"'; then
        echo "  FAIL: /status still carries Access-Control-Allow-Origin: * (#10c)"
        fail=$((fail + 1))
    else
        echo "  PASS: /status response does not carry Access-Control-Allow-Origin: *"
        pass=$((pass + 1))
    fi
fi

# Other endpoints (artwork / metadata / health / version) intentionally
# keep CORS — verify at least one such header still exists in the file.
assert 'grep -c "Access-Control-Allow-Origin" "$METADATA_PY" | grep -qE "^[1-9]"' \
       "other endpoints keep CORS headers (only /status was hardened)"

echo
echo "=== Wave-3: USB CARD detection via aplay -l (#8) ==="

assert 'grep -q "USB_CARD_ID" "$HAT_DETECT"' \
       "audio-hat-detect.sh exports USB_CARD_ID"
assert 'grep -q "aplay -l" "$HAT_DETECT"' \
       "audio-hat-detect.sh probes aplay -l for the actual card id"
assert 'grep -q "USB_CARD_ID" "$SETUP_SH"' \
       "setup.sh honours USB_CARD_ID override"
assert 'grep -qE "HAT_CARD_NAME=.*USB_CARD_ID" "$SETUP_SH"' \
       "setup.sh assigns USB_CARD_ID into HAT_CARD_NAME for usb-audio"

# The override block must be AFTER the conf source (line 305-306) but
# BEFORE the HAT_CARD_NAME validation (line ~317).
override_line=$(grep -n "HAT_CARD_NAME=\"\$USB_CARD_ID\"" "$SETUP_SH" | head -1 | cut -d: -f1)
source_line=$(grep -n 'source "\$HAT_CONFIG_FILE"' "$SETUP_SH" | head -1 | cut -d: -f1)
validate_line=$(grep -n 'Required variables: HAT_NAME, HAT_CARD_NAME' "$SETUP_SH" | head -1 | cut -d: -f1)
if [[ -n "$override_line" && -n "$source_line" && -n "$validate_line" \
      && "$override_line" -gt "$source_line" \
      && "$override_line" -lt "$validate_line" ]]; then
    echo "  PASS: USB_CARD_ID override sits between conf source and validation (line $override_line)"
    pass=$((pass + 1))
else
    echo "  FAIL: USB_CARD_ID override misplaced (override=$override_line, source=$source_line, validate=$validate_line)"
    fail=$((fail + 1))
fi

echo
echo "=== audio-hat-detect.sh: apt-failure surfaces a WARN instead of being swallowed ==="
# Original `apt-get install ... >&2 || true` swallowed the failure silently.
# Downstream guards still skip the I2C scan when the binary is missing, but
# without a log line operators had to grep apt logs to understand WHY the
# scan was skipped. Both i2c-tools and kmod install attempts now log a
# distinct WARN line when apt fails — keeps the same control-flow but adds
# observability. Replacing the WARN with a silent fallback would re-introduce
# the regression.
assert '! grep -qE "apt-get install -y -q (i2c-tools|kmod) >&2 *\\|\\| *true" "$HAT_DETECT"' \
       "apt-get install fail is no longer silently swallowed with || true"
assert 'grep -qE "apt-get install i2c-tools failed" "$HAT_DETECT"' \
       "i2c-tools install failure logs an explicit WARN"
assert 'grep -qE "apt-get install kmod failed" "$HAT_DETECT"' \
       "kmod install failure logs an explicit WARN"

echo
if (( fail > 0 )); then
    echo "FAILED: $fail / $((pass + fail))"
    exit 1
fi
echo "All $pass tests passed!"
