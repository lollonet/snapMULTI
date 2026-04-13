#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

echo "Testing HAT configuration files..."

# Test all HAT configs load successfully
for conf in "$PROJECT_DIR/common/audio-hats/"*.conf; do
    # shellcheck source=/dev/null
    source "$conf"

    # Validate required variables
    [[ -n "$HAT_NAME" ]] || { echo "❌ FAIL: HAT_NAME missing in $conf"; exit 1; }
    [[ -n "$HAT_CARD_NAME" ]] || { echo "❌ FAIL: HAT_CARD_NAME missing in $conf"; exit 1; }
    [[ -n "$HAT_TYPE" ]] || { echo "❌ FAIL: HAT_TYPE missing in $conf"; exit 1; }
    [[ -n "$HAT_FORMAT" ]] || { echo "❌ FAIL: HAT_FORMAT missing in $conf"; exit 1; }
    [[ -n "$HAT_RATE" ]] || { echo "❌ FAIL: HAT_RATE missing in $conf"; exit 1; }
    [[ "${HAT_MIXER:-}" =~ ^(software|hardware:.+)$ ]] || { echo "❌ FAIL: HAT_MIXER invalid or missing in $conf"; exit 1; }

    echo "✓ $HAT_NAME"
done

echo ""
echo "✅ All HAT configs valid!"
