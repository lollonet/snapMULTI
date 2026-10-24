#!/usr/bin/env bash
# Behavioural test for deploy.sh setup_env() on re-deploys over an
# existing .env. The functions are extracted from deploy.sh and run
# against a sandbox .env (deploy.sh itself needs root + Docker).
#
# Regressions covered:
#   - unchanged profile `return 0`ed before release identity was persisted
#     → git pull + redeploy kept a stale IMAGE_TAG / SNAPMULTI_RELEASE
#   - unchanged profile never refreshed limits changed by a new release
#   - profile change deleted + re-appended the block, moving it after user
#     overrides (which then lost: later keys win in a Compose .env)
#   - SNAPMULTI_RELEASE blanked while a stale IMAGE_TAG survived
#   - removing `tidal` from COMPOSE_PROFILES was undone on every deploy;
#     TIDAL_ENABLED=false is now the explicit, sticky opt-out
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY="$SCRIPT_DIR/../scripts/deploy.sh"

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

SBX="$(mktemp -d)"
trap 'rm -rf "$SBX"' EXIT
ENV_FILE="$SBX/.env"
LOG="$SBX/log"

# Logging + host stubs.
info()  { echo "INFO $*" >> "$LOG"; }
warn()  { echo "WARN $*" >> "$LOG"; }
ok()    { :; }
step()  { :; }
error() { echo "ERROR $*" >> "$LOG"; }
detect_real_user() { id -un; }
is_network_mount() { return 1; }
detect_music_library() { echo ""; }
chown() { :; }
# shellcheck source=../scripts/common/release-manifest.sh
source "$SCRIPT_DIR/../scripts/common/release-manifest.sh"

extract_fn() {
    awk -v fn="$1" '$0 ~ "^" fn "\\(\\) \\{" {on=1} on {print} on && /^}/ {exit}' "$DEPLOY"
}
for fn in resource_profile_block current_profile_block apply_resource_profile \
          persist_env_kv _compose_profiles ensure_profile remove_compose_profile \
          tidal_opted_out setup_env; do
    body=$(extract_fn "$fn")
    if [[ -z "$body" ]]; then
        echo "FAIL: could not extract $fn() from deploy.sh"
        exit 1
    fi
    eval "$body"
done

# Run setup_env in a subshell with a clean release-identity environment.
# Usage: run_setup <profile> [VAR=value ...]
run_setup() {
    local profile="$1"; shift
    : > "$LOG"
    (
        unset SNAPMULTI_RELEASE SNAPMULTI_IMAGE_SET IMAGE_TAG MUSIC_PATH MUSIC_SOURCE
        for kv in "$@"; do export "${kv?}"; done
        IS_ARM="${IS_ARM:-true}"
        TIDAL_OPTED_OUT=false
        setup_env "$profile" >/dev/null 2>&1
        echo "TIDAL_OPTED_OUT=$TIDAL_OPTED_OUT" >> "$LOG"
    )
}

envval() { grep -m1 "^$1=" "$ENV_FILE" | cut -d= -f2-; }
blocks() { grep -c '^# Hardware Profile: BEGIN' "$ENV_FILE"; }

echo "## Fresh install"
run_setup standard IS_ARM=true SNAPMULTI_RELEASE=v0.8.6 SNAPMULTI_IMAGE_SET=0.7.6 IMAGE_TAG=0.7.6
assert "[[ \"\$(envval SNAPMULTI_PROFILE)\" == standard ]]" "profile block written"
assert "[[ \"\$(envval COMPOSE_PROFILES)\" == tidal ]]" "tidal profile enabled on ARM"
assert "[[ \"\$(envval IMAGE_TAG)\" == 0.7.6 ]]" "IMAGE_TAG persisted"
assert "[[ \"\$(envval SNAPMULTI_RELEASE)\" == v0.8.6 ]]" "SNAPMULTI_RELEASE persisted"

echo
echo "## Re-deploy, same profile, new release (git pull + redeploy)"
printf '\n# my settings\nMY_KEY=keepme\n' >> "$ENV_FILE"
run_setup standard IS_ARM=true SNAPMULTI_RELEASE=v0.8.7 SNAPMULTI_IMAGE_SET=0.7.7 IMAGE_TAG=0.7.7
assert "[[ \"\$(envval IMAGE_TAG)\" == 0.7.7 ]]" "IMAGE_TAG updated despite unchanged profile"
assert "[[ \"\$(envval SNAPMULTI_RELEASE)\" == v0.8.7 ]]" "SNAPMULTI_RELEASE updated despite unchanged profile"
assert "[[ \"\$(envval SNAPMULTI_IMAGE_SET)\" == 0.7.7 ]]" "SNAPMULTI_IMAGE_SET updated despite unchanged profile"
assert "grep -q 'already configured' '$LOG'" "identical profile block left alone"
assert "[[ \"\$(envval MY_KEY)\" == keepme ]]" "user key preserved"

echo
echo "## Re-deploy, same profile, limits changed by the new release"
sed -i 's/^MPD_MEM_LIMIT=.*/MPD_MEM_LIMIT=256M/' "$ENV_FILE"
printf 'SPOTIFY_MEM_LIMIT=999M\n' >> "$ENV_FILE"   # user override after the block
run_setup standard IS_ARM=true SNAPMULTI_RELEASE=v0.8.7 SNAPMULTI_IMAGE_SET=0.7.7 IMAGE_TAG=0.7.7
assert "[[ \"\$(awk '/^# Hardware Profile: BEGIN/,/^# Hardware Profile: END/' '$ENV_FILE' | grep -m1 '^MPD_MEM_LIMIT=' | cut -d= -f2)\" == 384M ]]" \
    "stale in-block limit refreshed to the current profile value"
assert "grep -q 'MPD_MEM_LIMIT: 256M -> 384M' '$LOG'" "changed limit logged"
assert "[[ \"\$(blocks)\" == 1 ]]" "exactly one profile block"
assert "[[ \"\$(grep '^SPOTIFY_MEM_LIMIT=' '$ENV_FILE' | tail -1)\" == SPOTIFY_MEM_LIMIT=999M ]]" \
    "user override after the block is still the last (effective) value"
assert "[[ \"\$(envval MY_KEY)\" == keepme ]]" "user key preserved"

echo
echo "## Profile change replaces the block in place"
run_setup performance IS_ARM=true SNAPMULTI_RELEASE=v0.8.7 SNAPMULTI_IMAGE_SET=0.7.7 IMAGE_TAG=0.7.7
assert "[[ \"\$(envval SNAPMULTI_PROFILE)\" == performance ]]" "profile switched to performance"
assert "[[ \"\$(blocks)\" == 1 ]]" "exactly one profile block"
end_line=$(grep -n '^# Hardware Profile: END' "$ENV_FILE" | cut -d: -f1)
override_line=$(grep -n '^SPOTIFY_MEM_LIMIT=999M' "$ENV_FILE" | cut -d: -f1)
assert "(( ${override_line:-0} > ${end_line:-999999} ))" "user override still after the block (not overridden by it)"

echo
echo "## Manual re-run without release identity keeps the recorded one"
run_setup performance IS_ARM=true
assert "[[ \"\$(envval IMAGE_TAG)\" == 0.7.7 ]]" "IMAGE_TAG kept"
assert "[[ \"\$(envval SNAPMULTI_RELEASE)\" == v0.8.7 ]]" "SNAPMULTI_RELEASE not blanked"

echo
echo "## Release without image set resets a stale IMAGE_TAG pin coherently"
run_setup performance IS_ARM=true SNAPMULTI_RELEASE=v0.9.0
assert "[[ \"\$(envval IMAGE_TAG)\" == latest ]]" "stale IMAGE_TAG replaced by latest"
assert "[[ \"\$(envval SNAPMULTI_RELEASE)\" == v0.9.0 ]]" "SNAPMULTI_RELEASE updated"

echo
echo "## Tidal opt-out"
persist_env_kv COMPOSE_PROFILES "foo,tidal"
printf 'TIDAL_ENABLED=false\n' >> "$ENV_FILE"
run_setup performance IS_ARM=true SNAPMULTI_IMAGE_SET=0.7.7 IMAGE_TAG=0.7.7
assert "[[ \"\$(envval COMPOSE_PROFILES)\" == foo ]]" "TIDAL_ENABLED=false strips tidal"
assert "grep -q 'TIDAL_OPTED_OUT=true' '$LOG'" "start_services told to remove the old container"
run_setup performance IS_ARM=true SNAPMULTI_IMAGE_SET=0.7.7 IMAGE_TAG=0.7.7
assert "[[ \"\$(envval COMPOSE_PROFILES)\" == foo ]]" "opt-out sticks across re-deploys"
persist_env_kv TIDAL_ENABLED '"No"'
persist_env_kv COMPOSE_PROFILES "tidal"
run_setup performance IS_ARM=true SNAPMULTI_IMAGE_SET=0.7.7 IMAGE_TAG=0.7.7
assert "[[ -z \"\$(envval COMPOSE_PROFILES)\" ]]" 'TIDAL_ENABLED="No" (quoted, mixed case) also opts out'
persist_env_kv TIDAL_ENABLED true
persist_env_kv COMPOSE_PROFILES "foo"
run_setup performance IS_ARM=true SNAPMULTI_IMAGE_SET=0.7.7 IMAGE_TAG=0.7.7
assert "[[ \"\$(envval COMPOSE_PROFILES)\" == foo,tidal ]]" "TIDAL_ENABLED=true keeps the default (tidal re-added)"
assert "grep -q 'TIDAL_OPTED_OUT=false' '$LOG'" "no container removal without opt-out"
persist_env_kv COMPOSE_PROFILES "foo"
run_setup performance IS_ARM=false SNAPMULTI_IMAGE_SET=0.7.7 IMAGE_TAG=0.7.7
assert "[[ \"\$(envval COMPOSE_PROFILES)\" == foo ]]" "non-ARM never adds tidal"

echo
echo "## Summary"
echo "  Passed: $pass"
echo "  Failed: $fail"
[[ $fail -eq 0 ]]
