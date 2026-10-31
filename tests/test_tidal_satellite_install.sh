#!/usr/bin/env bash
# Tidal satellite on a client SD install:
#
# - the staged client/tidal-satellite/ tree resolves every relative bind
#   mount of contrib/tidal-satellite/docker-compose.yml (../../scripts/tidal,
#   ../../config), so firstboot can run the compose file unchanged
# - get_tidal_satellite_config: Enter skips, a valid host is kept, an
#   invalid one is asked again
# - install.conf writers (bash + PowerShell) emit TIDAL_SATELLITE_SERVER
# - firstboot sanitizes the key, rejects it on non-client profiles, and
#   starts + verifies the satellite before finalize arms overlayroot
# - device-smoke checks the satellite stack when its .env exists

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PREP="$PROJECT_DIR/scripts/prepare-sd.sh"
PS1_FILE="$PROJECT_DIR/scripts/prepare-sd.ps1"
FIRSTBOOT="$PROJECT_DIR/scripts/firstboot.sh"
SMOKE="$PROJECT_DIR/scripts/device-smoke.sh"

pass=0
fail=0

ok() { echo "  PASS: $1"; pass=$((pass + 1)); }
ko() { echo "  FAIL: $1"; fail=$((fail + 1)); }

assert_eq() {
    if [[ "$1" == "$2" ]]; then ok "$3"; else ko "$3 (got '$1', expected '$2')"; fi
}

assert_contains() {
    if grep -qF -- "$2" <<<"$1"; then ok "$3"; else ko "$3 (missing '$2')"; fi
}

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

echo "=== staged tree resolves the satellite bind mounts ==="
# shellcheck source=../scripts/common/staging-manifest.sh
source "$PROJECT_DIR/scripts/common/staging-manifest.sh"
bundle="$TMP/client"
mkdir -p "$bundle"
for i in "${!STAGING_CLIENT_REQUIRED[@]}"; do
    case "${STAGING_CLIENT_REQUIRED_DESTS[$i]}" in
        tidal-satellite/*)
            stage_manifest_entry "${STAGING_CLIENT_REQUIRED[$i]}" "$bundle" \
                "${STAGING_CLIENT_REQUIRED_DESTS[$i]}" "true"
            ;;
    esac
done
compose_dir="$bundle/tidal-satellite/contrib/tidal-satellite"
if [[ -f "$compose_dir/docker-compose.yml" ]]; then
    ok "compose file staged at client/tidal-satellite/contrib/tidal-satellite/"
else
    ko "compose file not staged"
fi
mounts=$(grep -oE '^ *- \.\./\.\./[^:]+' "$compose_dir/docker-compose.yml" | sed -E 's/^ *- //' || true)
if [[ -z "$mounts" ]]; then
    ko "no ../../ bind mounts found in the satellite compose file"
fi
while IFS= read -r m; do
    [[ -z "$m" ]] && continue
    if [[ -e "$compose_dir/$m" ]]; then ok "bind mount $m resolves"; else ko "bind mount $m missing in staged tree"; fi
done <<<"$mounts"

echo
echo "=== get_tidal_satellite_config ==="
# shellcheck disable=SC1090
source "$PROJECT_DIR/scripts/common/sanitize.sh"
eval "$(sed -n '/^get_tidal_satellite_config() {$/,/^}$/p' "$PREP")"
get_tidal_satellite_config < <(printf '\n') >/dev/null
assert_eq "$TIDAL_SATELLITE_SERVER" "" "Enter skips the satellite"
get_tidal_satellite_config < <(printf '192.168.63.3\n') >/dev/null
assert_eq "$TIDAL_SATELLITE_SERVER" "192.168.63.3" "IP is kept"
get_tidal_satellite_config < <(printf 'my server!\nnas.local\n') >/dev/null
assert_eq "$TIDAL_SATELLITE_SERVER" "nas.local" "invalid host is asked again"

echo
echo "=== install.conf writers ==="
assert_contains "$(<"$PREP")" 'TIDAL_SATELLITE_SERVER=$TIDAL_SATELLITE_SERVER' "prepare-sd.sh writes TIDAL_SATELLITE_SERVER"
assert_contains "$(<"$PS1_FILE")" 'TIDAL_SATELLITE_SERVER=$TidalSatelliteServer' "prepare-sd.ps1 writes TIDAL_SATELLITE_SERVER"
assert_contains "$(<"$PS1_FILE")" "'client/tidal-satellite/contrib/tidal-satellite/docker-compose.yml'" "prepare-sd.ps1 verifies the staged satellite"
assert_contains "$(<"$PROJECT_DIR/install.conf.template")" "TIDAL_SATELLITE_SERVER=" "install.conf.template documents the key"

echo
echo "=== firstboot ==="
fb=$(<"$FIRSTBOOT")
assert_contains "$fb" 'TIDAL_SATELLITE_SERVER=$(sanitize_hostname "$(install_conf_get TIDAL_SATELLITE_SERVER' "firstboot sanitizes the key"
assert_contains "$fb" 'if [[ -n "$TIDAL_SATELLITE_SERVER" && "$INSTALL_TYPE" != "client" ]]; then' "firstboot rejects the satellite on non-client profiles"
sat_line=$(grep -n 'checkpoint_done "tidal-satellite"' "$FIRSTBOOT" | head -1 | cut -d: -f1)
ro_line=$(grep -n 'setup_readonly_fs "\$RO_MODE_SCRIPT"' "$FIRSTBOOT" | head -1 | cut -d: -f1)
if [[ -n "$sat_line" && -n "$ro_line" && "$sat_line" -lt "$ro_line" ]]; then
    ok "satellite starts before overlayroot is armed (line $sat_line < $ro_line)"
else
    ko "satellite step must come before setup_readonly_fs (sat=$sat_line ro=$ro_line)"
fi
assert_contains "$fb" 'verify_compose_stack "$_sat_compose_dir/docker-compose.yml" "tidal-satellite"' "firstboot verifies the satellite stack"

echo
echo "=== device-smoke ==="
assert_contains "$(<"$SMOKE")" 'check_compose_stack /opt/tidal-satellite/contrib/tidal-satellite/docker-compose.yml "tidal-satellite"' "device-smoke checks the satellite stack"

echo
echo "Results: $pass passed, $fail failed"
exit $(( fail > 0 ? 1 : 0 ))
