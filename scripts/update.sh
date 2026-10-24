#!/usr/bin/env bash
# snapMULTI update stub
#
# In-place updates are no longer supported (ADR-005).
# The primary update method is reflashing the SD card.
#
# See: https://github.com/lollonet/snapMULTI/releases
# See: docs/ADVANCED.md#updating-by-reflash (ordered procedure)
# See: docs/adr/ADR-005.reflash-systemd-robustness.md
set -euo pipefail

echo ""
echo "In-place updates are no longer supported."
echo ""
echo "To update snapMULTI, reflash the SD card (about 15-20 min on a Pi 4/5):"
echo "  1. Power off this Pi (sudo poweroff) and put its SD card in your computer."
echo "  2. Download and extract the latest release:"
echo "     https://github.com/lollonet/snapMULTI/releases/latest"
echo "  3. Server installs: BEFORE flashing, run ./scripts/backup-from-sd.sh"
echo "     from the release folder (macOS/Linux). It saves the MPD database,"
echo "     myMPD playlists/settings and speaker groups from the old card so"
echo "     the new install restores them. Skip this and all three start"
echo "     from scratch. Windows: copy them out of the card's"
echo "     snapmulti-backup folder by hand (see the docs link below)."
echo "  4. Flash the card with Raspberry Pi Imager (same hostname, user, WiFi)."
echo "  5. Run prepare-sd.sh (or prepare-sd.ps1) and answer its questions again."
echo "  6. After first boot, re-apply any custom .env settings."
echo ""
echo "Full procedure: docs/ADVANCED.md#updating-by-reflash"
echo ""
exit 1
