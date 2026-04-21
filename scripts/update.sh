#!/usr/bin/env bash
# snapMULTI update stub
#
# In-place updates are no longer supported (ADR-005).
# The primary update method is reflashing the SD card.
#
# See: https://github.com/lollonet/snapMULTI/releases
# See: docs/adr/ADR-005.reflash-systemd-robustness.md
set -euo pipefail

echo ""
echo "In-place updates are no longer supported."
echo ""
echo "To update snapMULTI:"
echo "  1. Download the latest release from:"
echo "     https://github.com/lollonet/snapMULTI/releases"
echo "  2. Reflash the SD card using prepare-sd.sh"
echo "  3. All configuration is auto-detected on first boot"
echo ""
echo "Your MPD database is automatically backed up to the boot partition."
echo "It will be restored after reflashing (no rescan needed)."
echo ""
echo "See: docs/adr/ADR-005.reflash-systemd-robustness.md"
exit 1
