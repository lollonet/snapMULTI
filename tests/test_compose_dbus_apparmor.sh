#!/usr/bin/env bash
# Every service that mounts the host D-Bus socket must run apparmor=unconfined.
#
# Docker's default AppArmor profile (docker-default) denies D-Bus method
# calls. Raspberry Pi OS does not enforce AppArmor, so the mount alone works
# there; on an AppArmor host (Ubuntu, Debian with AppArmor) the container's
# Avahi client fails with "Access denied" and the service is never announced.
# The &fifo-security anchor carries the setting; a service that sets its own
# security_opt must repeat it.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

pass=0
fail=0

# Print each "service<TAB>line" of the services: section of a compose file.
service_lines() {
    awk '
        /^services:/ { on = 1; next }
        on && /^[^[:space:]#]/ { on = 0 }
        on && /^  [a-z][a-z0-9_-]*:$/ { svc = $1; sub(":", "", svc); next }
        on && svc { print svc "\t" $0 }
    ' "$1"
}

for compose in "$SCRIPT_DIR/../docker-compose.yml" "$SCRIPT_DIR/../contrib/tidal-satellite/docker-compose.yml"; do
    rel="${compose#"$SCRIPT_DIR/../"}"
    echo "## $rel"
    lines=$(service_lines "$compose")
    dbus_services=$(awk -F'\t' '$2 ~ /dbus(\/system_bus_socket)?:/ {print $1}' <<< "$lines" | sort -u)
    if [[ -z "$dbus_services" ]]; then
        echo "  (no service mounts D-Bus)"
        continue
    fi
    for svc in $dbus_services; do
        if awk -F'\t' -v s="$svc" '$1 == s && ($2 ~ /apparmor=unconfined/ || $2 ~ /<<: \*fifo-security/) {found=1} END {exit !found}' <<< "$lines"; then
            echo "  PASS: $svc mounts D-Bus and runs apparmor=unconfined"
            pass=$((pass + 1))
        else
            echo "  FAIL: $svc mounts D-Bus without apparmor=unconfined"
            fail=$((fail + 1))
        fi
    done
done

echo
echo "## Summary"
echo "  Passed: $pass"
echo "  Failed: $fail"
[[ $fail -eq 0 ]]
