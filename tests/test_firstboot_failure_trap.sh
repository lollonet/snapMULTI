#!/usr/bin/env bash
# firstboot.sh failure handling.
#
#   1. The EXIT trap is installed before ANY early exit (missing
#      $SNAP_BOOT, malformed install.conf, Pi Zero 2W server guard, a
#      module that fails to source), so every abort leaves the failure
#      marker + a console message. Previously these exits happened before
#      `trap cleanup_on_failure EXIT` and left nothing behind.
#   2. The trap works before the logger / install dirs exist (set -u safe).
#   3. Messages state the manual recovery: nothing re-runs firstboot
#      (cloud-init runcmd is once-per-instance), so "will retry on next
#      boot" was false.
#   4. Headless installs get the audible fail tone (best-effort, bounded).
#   5. Client path: setup.sh (under firstboot) no longer arms overlayroot
#      before the image pull / client verify; firstboot's finalize does.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FIRSTBOOT="$SCRIPT_DIR/../scripts/firstboot.sh"
CLIENT_SETUP="$SCRIPT_DIR/../client/common/scripts/setup.sh"

pass=0
fail=0
ok()  { echo "  PASS: $1"; pass=$((pass + 1)); }
bad() { echo "  FAIL: $1"; fail=$((fail + 1)); }
line_of() { grep -nE "$1" "$2" | head -1 | cut -d: -f1 || true; }

TMPD=$(mktemp -d)
trap 'rm -rf "$TMPD"' EXIT

echo "=== Static: trap installed before every early exit ==="
trap_line=$(line_of '^trap cleanup_on_failure EXIT$' "$FIRSTBOOT")
[[ -n "$trap_line" ]] && ok "trap cleanup_on_failure EXIT present (line $trap_line)" || bad "trap line missing"
for pat in '^if \[\[ ! -d "\$SNAP_BOOT" \]\]; then' \
           '^source "\$SNAP_BOOT/common/install-conf-reader.sh"' \
           '^source "\$COMMON/unified-log.sh"' \
           '^if ! install_profile_is_valid "\$INSTALL_TYPE"; then' \
           '^_validate_profile_hardware$' \
           '^source "\$COMMON/progress.sh"'; do
    l=$(line_of "$pat" "$FIRSTBOOT")
    if [[ -n "$l" && -n "$trap_line" && "$trap_line" -lt "$l" ]]; then
        ok "trap (line $trap_line) precedes: $pat (line $l)"
    else
        bad "trap must precede '$pat' (trap=$trap_line, target=$l)"
    fi
done
if [[ "$(grep -c '^trap cleanup_on_failure EXIT$' "$FIRSTBOOT")" -eq 1 ]]; then
    ok "trap installed exactly once"
else
    bad "trap installed more than once"
fi

echo
echo "=== Static: recovery wording ==="
if grep -qi 'retry on next boot' "$FIRSTBOOT"; then
    bad "firstboot.sh still promises a retry on next boot"
else
    ok "no 'retry on next boot' promise in firstboot.sh"
fi
body=$(sed -n '/^cleanup_on_failure() {/,/^}/p' "$FIRSTBOOT")
grep -qF 'sudo bash $SNAP_BOOT/firstboot.sh' <<<"$body" && ok "trap names the manual re-run command" || bad "trap lacks the re-run command"
grep -qF 'FAIL_REFLASH_ONLY' <<<"$body" && ok "trap distinguishes reflash-only configuration errors" || bad "no reflash-only branch"
for guard in 'Reflash this SD with the prepare-sd.sh menu.' 'See docs/HARDWARE.md for the supported hardware matrix.'; do
    if grep -A1 -F "$guard" "$FIRSTBOOT" | grep -qF 'FAIL_REFLASH_ONLY=true'; then
        ok "config guard marks reflash-only: $guard"
    else
        bad "config guard does not set FAIL_REFLASH_ONLY: $guard"
    fi
done

echo
echo "=== Static: failure tone ==="
grep -qF '_play_failure_tone' <<<"$body" && ok "cleanup_on_failure plays the fail tone" || bad "no fail tone in cleanup_on_failure"
tone=$(sed -n '/^_play_failure_tone() {/,/^}/p' "$FIRSTBOOT")
grep -qE 'timeout [0-9]+ bash "\$tone_script" fail' <<<"$tone" && ok "tone call is bounded by timeout" || bad "tone call not bounded"
grep -qF '|| true' <<<"$tone" && ok "tone failure never propagates" || bad "tone failure may propagate"
grep -qF '/proc/asound/cards' <<<"$tone" && ok "tone skipped without an ALSA card" || bad "no ALSA card check"
grep -qF 'play-smoke-tone.sh' <<<"$tone" && ok "uses the staged play-smoke-tone.sh" || bad "does not use play-smoke-tone.sh"

echo
echo "=== Functional: trap fires before logger/progress exist ==="
# Extract the early trap block verbatim and run it in a minimal shell
# that has none of the later state (no unified-log, no SERVER_DIR, no
# PROGRESS_TTY, no CURRENT_MODULE) under set -euo pipefail.
blk="$TMPD/trap_block.sh"
sed -n '/^FAIL_REFLASH_ONLY=false$/,/^trap cleanup_on_failure EXIT$/p' "$FIRSTBOOT" > "$blk"
[[ -s "$blk" ]] && ok "trap block extracted" || bad "could not extract trap block"

run_early_exit() {
    local reflash="$1" rc_wanted="$2"
    local d="$TMPD/run-$reflash-$rc_wanted"
    mkdir -p "$d/state" "$d/boot/snapmulti"
    cat > "$d/run.sh" <<EOF
set -euo pipefail
INSTALLER_STATE="$d/state"
FAILED_MARKER="\$INSTALLER_STATE/.install-failed"
BOOT="$d/boot"
SNAP_BOOT="\$BOOT/snapmulti"
SCRIPT_DIR="$d"
export UNIFIED_LOG="$d/install.log"
chvt() { :; }
source "$blk"
FAIL_REFLASH_ONLY=$reflash
exit $rc_wanted
EOF
    local rc=0
    bash "$d/run.sh" >"$d/stdout" 2>"$d/stderr" || rc=$?
    echo "$rc"
}

d="$TMPD/run-false-3"
rc=$(run_early_exit false 3)
[[ "$rc" == "3" ]] && ok "exit code preserved through the trap (3)" || bad "exit code changed: $rc"
[[ -s "$d/state/.install-failed" ]] && ok "failure marker written on an early exit" || bad "no failure marker on early exit"
grep -qF 'Installation FAILED in module: init' "$d/install.log" 2>/dev/null && ok "failure logged to the install log without unified-log.sh" || bad "failure not logged"
grep -qF "sudo bash $d/boot/snapmulti/firstboot.sh" "$d/stderr" && ok "re-run command printed" || bad "re-run command not printed"
if grep -qi 'unbound variable' "$d/stderr"; then bad "trap hit an unbound variable (set -u)"; else ok "trap is set -u clean before init"; fi

d="$TMPD/run-true-1"
rc=$(run_early_exit true 1)
[[ "$rc" == "1" ]] && ok "reflash-only exit preserved (1)" || bad "reflash-only exit code changed: $rc"
grep -qF 'reflash the SD card' "$d/stderr" && ok "reflash-only errors tell the user to reflash" || bad "reflash hint missing"
if grep -qF 'sudo bash' "$d/stderr"; then bad "reflash-only error still suggests a re-run"; else ok "reflash-only error does not suggest a pointless re-run"; fi

d="$TMPD/run-false-0"
rc=$(run_early_exit false 0)
[[ "$rc" == "0" ]] && ok "clean exit stays 0" || bad "clean exit changed: $rc"
[[ ! -e "$d/state/.install-failed" ]] && ok "no failure marker on success" || bad "failure marker written on success"

echo
echo "=== Client path: overlayroot armed only after verify ==="
ro_body=$(sed -n '/^_configure_readonly()/,/^}/p' "$CLIENT_SETUP")
guard_l=$(grep -nF 'SNAPMULTI_DEFER_OVERLAYROOT:-0' <<<"$ro_body" | head -1 | cut -d: -f1 || true)
ckpt_l=$(grep -nF 'printf '"'"'%s\n'"'"' "$(date -u +%FT%TZ)" > "$_switch_checkpoint"' <<<"$ro_body" | head -1 | cut -d: -f1 || true)
raspi_l=$(grep -nF 'raspi-config nonint do_overlayfs 0' <<<"$ro_body" | head -1 | cut -d: -f1 || true)
if [[ -n "$guard_l" && -n "$ckpt_l" && -n "$raspi_l" && "$ckpt_l" -lt "$guard_l" && "$guard_l" -lt "$raspi_l" ]]; then
    ok "setup.sh defers after the fuse-overlayfs switch and before raspi-config"
else
    bad "deferral guard misplaced (ckpt=$ckpt_l guard=$guard_l raspi=$raspi_l)"
fi
grep -qF '"$AUTO_MODE" == true && "${SNAPMULTI_DEFER_OVERLAYROOT:-0}" == "1"' <<<"$ro_body" \
    && ok "deferral requires --auto (standalone setup.sh unchanged)" || bad "deferral not limited to --auto"
export_l=$(line_of '^    export SNAPMULTI_DEFER_OVERLAYROOT=1$' "$FIRSTBOOT")
run_l=$(line_of 'bash "\$setup_script" "\$\{setup_args\[@\]\}"' "$FIRSTBOOT")
verify_l=$(line_of 'verify_compose_stack "\$CLIENT_DIR/docker-compose.yml" "client"' "$FIRSTBOOT")
ro_l=$(line_of '^    setup_readonly_fs "\$RO_MODE_SCRIPT"$' "$FIRSTBOOT")
if [[ -n "$export_l" && -n "$run_l" && -n "$verify_l" && -n "$ro_l" ]] \
   && (( export_l < run_l && run_l < verify_l && verify_l < ro_l )); then
    ok "firstboot: export flag < setup.sh < client verify < setup_readonly_fs"
else
    bad "firstboot ordering wrong (export=$export_l run=$run_l verify=$verify_l ro=$ro_l)"
fi

# Functional: run _configure_readonly with stubs, paths remapped into TMPD.
fn="$TMPD/configure_readonly.sh"
sed -e "s|/var/lib/snapmulti-installer|$TMPD/state|g" -e "s|/etc/|$TMPD/etc/|g" \
    <<<"$ro_body" > "$fn"
run_configure_readonly() {
    local auto="$1" defer="$2"
    rm -rf "${TMPD:?}/state" "${TMPD:?}/etc" "${TMPD:?}/calls"
    mkdir -p "$TMPD/state"
    printf 'done\n' > "$TMPD/state/.done-fuse-overlayfs-switched"
    (
        set -euo pipefail
        CALLS="$TMPD/calls"
        AUTO_MODE="$auto"
        ENABLE_READONLY=true
        COMMON_DIR="$TMPD"; COMMON_MODULE_DIR="$TMPD"; UNIFIED_LOG=/dev/null
        export SNAPMULTI_DEFER_OVERLAYROOT="$defer"
        progress() { :; }
        log_progress() { :; }
        apt-get() { :; }
        fuse-overlayfs() { :; }
        tune_docker_daemon() { echo "tune_docker_daemon $*" >> "$CALLS"; }
        prepare_readonly_helpers() { echo prepare_readonly_helpers >> "$CALLS"; }
        install_initramfs_lzma_hook() { :; }
        refresh_overlayroot_modules_dep() { :; }
        persist_overlayroot_enabled() { return 0; }
        raspi-config() { echo "raspi-config $*" >> "$CALLS"; }
        # shellcheck disable=SC1090
        source "$fn"
        _configure_readonly >/dev/null
        echo "ENABLE_READONLY=$ENABLE_READONLY" >> "$CALLS"
    )
}
run_configure_readonly true 1
grep -qF 'tune_docker_daemon --live-restore --fuse-overlayfs' "$TMPD/calls" && ok "deferred: Docker still prepared for fuse-overlayfs" || bad "deferred: Docker not prepared"
if grep -qF 'raspi-config' "$TMPD/calls"; then bad "deferred: raspi-config still called"; else ok "deferred: overlayroot NOT armed by setup.sh"; fi
grep -qF 'ENABLE_READONLY=true' "$TMPD/calls" && ok "deferred: ENABLE_READONLY stays true" || bad "deferred: ENABLE_READONLY flipped"
run_configure_readonly false 1
grep -qF 'raspi-config nonint do_overlayfs 0' "$TMPD/calls" && ok "standalone (no --auto): overlayroot still armed by setup.sh" || bad "standalone: overlayroot not armed"
run_configure_readonly true 0
grep -qF 'raspi-config nonint do_overlayfs 0' "$TMPD/calls" && ok "--auto without the firstboot flag: unchanged behaviour" || bad "--auto without flag: overlayroot not armed"

echo
echo "Results: $pass passed, $fail failed"
exit $(( fail > 0 ? 1 : 0 ))
