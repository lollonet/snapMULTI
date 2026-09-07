#!/usr/bin/env bash
# Regression coverage for full state transfer through host staging and firstboot.
# shellcheck disable=SC1091,SC2016,SC2034
# The manifest path is dynamic; assert() evaluates conditions that reference
# variables indirectly, which ShellCheck cannot follow.

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/.." && pwd)"
MANIFEST="$REPO_ROOT/scripts/common/staging-manifest.sh"
PREP_PS="$REPO_ROOT/scripts/prepare-sd.ps1"
FIRSTBOOT="$REPO_ROOT/scripts/firstboot.sh"
DEPLOY="$REPO_ROOT/scripts/deploy.sh"
SBX=$(mktemp -d /tmp/snapmulti-persistence-transfer-XXXXXX)
trap 'rm -rf "$SBX"' EXIT

pass=0
fail=0

assert() {
    local condition="$1" description="$2"
    if eval "$condition"; then
        echo "  PASS: $description"
        pass=$((pass + 1))
    else
        echo "  FAIL: $description"
        fail=$((fail + 1))
    fi
}

# shellcheck source=../scripts/common/staging-manifest.sh
source "$MANIFEST"

manifest_dest_for() {
    local wanted="$1" i
    for i in "${!STAGING_SERVER_OPTIONAL[@]}"; do
        if [[ "${STAGING_SERVER_OPTIONAL[$i]}" == "$wanted" ]]; then
            printf '%s\n' "${STAGING_SERVER_OPTIONAL_DESTS[$i]}"
            return 0
        fi
    done
    return 1
}

echo "=== Bash staging manifest ==="
assert '[[ "$(manifest_dest_for data/server.json 2>/dev/null)" == "data" ]]' "server.json is an optional server seed staged to data/"
assert '[[ "$(manifest_dest_for mympd/workdir 2>/dev/null)" == "mympd" ]]' "complete myMPD workdir is an optional server seed staged to mympd/"

# Exercise the production manifest copier with every music-source choice.
PROJECT_DIR="$SBX/source"
mkdir -p "$PROJECT_DIR/data" "$PROJECT_DIR/mympd/workdir/state"
echo "server seed" > "$PROJECT_DIR/data/server.json"
echo "myMPD seed" > "$PROJECT_DIR/mympd/workdir/state/theme"
for source in "" usb nfs smb; do
    export MUSIC_SOURCE="$source"
    bundle="$SBX/bundle-${source:-unset}/server"
    mkdir -p "$bundle"
    for entry in data/server.json mympd/workdir; do
        dest=$(manifest_dest_for "$entry")
        stage_manifest_entry "$entry" "$bundle" "$dest" false
    done
    assert '[[ -f "$bundle/data/server.json" ]]' "server.json stages with MUSIC_SOURCE=${source:-unset}"
    assert '[[ -f "$bundle/mympd/workdir/state/theme" ]]' "myMPD workdir stages with MUSIC_SOURCE=${source:-unset}"
done

echo
echo "=== Windows staging parity ==="
assert 'grep -q "data.server.json" "$PREP_PS"' "PowerShell stages data/server.json"
assert 'grep -q "mympd.workdir" "$PREP_PS"' "PowerShell stages the complete myMPD workdir"

echo
echo "=== firstboot seed ordering ==="
assert 'grep -q "SNAP_BOOT/server/data/server.json" "$FIRSTBOOT"' "firstboot copies the snapserver seed into the writable tree"
assert 'grep -q "SNAP_BOOT/server/mympd/workdir" "$FIRSTBOOT"' "firstboot copies the complete myMPD seed into the writable tree"
server_seed_line=$(grep -n 'SNAP_BOOT/server/data/server.json' "$FIRSTBOOT" | head -1 | cut -d: -f1 || true)
mympd_seed_line=$(grep -n 'SNAP_BOOT/server/mympd/workdir' "$FIRSTBOOT" | head -1 | cut -d: -f1 || true)
deploy_line=$(grep -n 'bash scripts/deploy.sh 2>&1' "$FIRSTBOOT" | head -1 | cut -d: -f1 || true)
assert '[[ -n "$server_seed_line" && -n "$deploy_line" && "$server_seed_line" -lt "$deploy_line" ]]' "snapserver seed is writable before deploy can start Compose"
assert '[[ -n "$mympd_seed_line" && -n "$deploy_line" && "$mympd_seed_line" -lt "$deploy_line" ]]' "myMPD seed is writable before deploy can start Compose"
assert 'grep -B70 "SNAP_BOOT/server/data/server.json" "$FIRSTBOOT" | grep -q "install_profile_needs_server_stack"' "seed restore is limited to server and both profiles"

seed_block=$(awk '
    /# Full-reflash persistence seeds are independent/ {capture=1}
    capture && /# Restore the MPD database backup/ {exit}
    capture {print}
' "$FIRSTBOOT")
assert '[[ -n "$seed_block" ]]' "firstboot seed block can be isolated for execution"

run_seed_block() (
    SNAP_BOOT="$1"
    SERVER_DIR="$2"
    log_info() { :; }
    log_error() { printf '%s\n' "$*" >&2; }
    eval "$seed_block"
)

seed_boot="$SBX/firstboot-success/boot"
seed_server="$SBX/firstboot-success/server"
mkdir -p "$seed_boot/server/data" "$seed_boot/server/mympd/workdir/state" "$seed_server"
echo "firstboot server seed" > "$seed_boot/server/data/server.json"
echo "firstboot myMPD seed" > "$seed_boot/server/mympd/workdir/state/theme"
run_seed_block "$seed_boot" "$seed_server"
assert 'grep -q "firstboot server seed" "$seed_server/data/server.json"' "executed firstboot block copies server.json"
assert 'grep -q "firstboot myMPD seed" "$seed_server/mympd/workdir/state/theme"' "executed firstboot block copies the complete myMPD seed"

fail_boot="$SBX/firstboot-failure/boot"
fail_server="$SBX/firstboot-failure/server"
mkdir -p "$fail_boot/server/data" "$fail_boot/server/mympd/workdir/state" "$fail_server" "$SBX/fail-bin"
echo "partial server seed" > "$fail_boot/server/data/server.json"
echo "rejected myMPD seed" > "$fail_boot/server/mympd/workdir/state/theme"
cat > "$SBX/fail-bin/cp" <<'EOF'
#!/bin/sh
case " $* " in
    *'/mympd/workdir/.'*) exit 42 ;;
esac
exec /bin/cp "$@"
EOF
chmod +x "$SBX/fail-bin/cp"
if PATH="$SBX/fail-bin:$PATH" run_seed_block "$fail_boot" "$fail_server" >/dev/null 2>&1; then
    echo "  FAIL: firstboot seed block propagates a partial copy failure"
    fail=$((fail + 1))
else
    echo "  PASS: firstboot seed block propagates a partial copy failure"
    pass=$((pass + 1))
fi
assert 'grep -q "partial server seed" "$fail_server/data/server.json"' "failure case reaches the second seed after copying server.json"
assert '[[ ! -f "$fail_server/mympd/workdir/state/theme" ]]' "failed myMPD copy is not reported as successful"

echo
echo "=== systemd owns the normal Compose start ==="
systemd_branch=$(awk '
    /if systemctl list-unit-files snapmulti-server[.]service/ {capture=1}
    capture && /^[[:space:]]*else$/ {exit}
    capture {print}
' "$DEPLOY")
assert '! grep -q "docker compose up" <<<"$systemd_branch"' "normal deploy does not start Compose before ExecStartPre"
assert 'grep -q "systemctl restart snapmulti-server.service" <<<"$systemd_branch"' "normal deploy re-enters systemd pre-start ordering"
assert '! grep -q "RuntimeDirectory=" "$DEPLOY"' "restore guard is not tied to a service RuntimeDirectory"

echo
echo "Results: $pass passed, $fail failed"
(( fail == 0 ))
