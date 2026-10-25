#!/usr/bin/env bash
# Functional tests for display-detect.sh (boot-time COMPOSE_PROFILES
# reconciliation). Runs the real script against a temp install dir with a
# stubbed has_display() and systemctl, and checks which profile lands in
# .env — in particular that a client installed headless (no hw:Loopback
# in asound.conf) is NOT switched to the framebuffer profile when an HDMI
# display is plugged in later.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DETECT_SH="$SCRIPT_DIR/../common/scripts/display-detect.sh"

pass=0
fail=0

assert_eq() {
    local actual="$1" expected="$2" desc="$3"
    if [[ "$actual" == "$expected" ]]; then
        echo "  PASS: $desc"
        pass=$((pass + 1))
    else
        echo "  FAIL: $desc (got '$actual', expected '$expected')"
        fail=$((fail + 1))
    fi
}

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# systemctl stub: unit is "active"; records restarts.
mkdir -p "$WORK/bin"
cat > "$WORK/bin/systemctl" <<'STUB'
#!/usr/bin/env bash
case "$1" in
    is-active) exit 0 ;;
    restart) echo "restart $2" >> "$SYSTEMCTL_LOG" ;;
esac
exit 0
STUB
chmod +x "$WORK/bin/systemctl"

ASOUND_DISPLAY='pcm.multi_out {
    type multi
    slaves {
        a { pcm "hw:sndrpihifiberry,0" channels 2 }
        b { pcm "hw:Loopback,0,0" channels 2 }
    }
}'
ASOUND_HEADLESS='pcm.!default {
    type plug
    slave {
        pcm "hw:sndrpihifiberry,0"
    }
}'

# run_case DISPLAY(yes|no) ASOUND_CONTENT INITIAL_PROFILE → sets PROFILE_OUT, RESTARTED, STDERR_OUT
run_case() {
    local display="$1" asound="$2" initial="$3" dir
    dir=$(mktemp -d "$WORK/inst-XXXX")
    mkdir -p "$dir/scripts"
    if [[ "$display" == "yes" ]]; then
        echo 'has_display() { return 0; }' > "$dir/scripts/display.sh"
    else
        echo 'has_display() { return 1; }' > "$dir/scripts/display.sh"
    fi
    if [[ -n "$asound" ]]; then
        printf '%s\n' "$asound" > "$dir/asound.conf"
    fi
    printf 'CLIENT_ID=test\nCOMPOSE_PROFILES=%s\n' "$initial" > "$dir/.env"
    export SYSTEMCTL_LOG="$dir/systemctl.log"
    STDERR_OUT=$(SNAPCLIENT_DIR="$dir" SNAPCLIENT_ASOUND_CONF="$dir/asound.conf" \
        PATH="$WORK/bin:$PATH" bash "$DETECT_SH" 2>&1 >/dev/null) || true
    PROFILE_OUT=$(grep '^COMPOSE_PROFILES=' "$dir/.env" | cut -d= -f2-)
    RESTARTED=no
    if [[ -s "$SYSTEMCTL_LOG" ]]; then
        RESTARTED=yes
    fi
}

echo "Testing display-detect.sh..."

run_case yes "$ASOUND_DISPLAY" ""
assert_eq "$PROFILE_OUT" "framebuffer" "display + loopback asound.conf → framebuffer"
assert_eq "$RESTARTED" "yes" "profile change restarts snapclient.service"

run_case yes "$ASOUND_DISPLAY" "framebuffer"
assert_eq "$PROFILE_OUT" "framebuffer" "display unchanged → framebuffer kept"
assert_eq "$RESTARTED" "no" "unchanged profile → no restart"

run_case no "$ASOUND_DISPLAY" "framebuffer"
assert_eq "$PROFILE_OUT" "" "display unplugged → headless"

run_case yes "$ASOUND_HEADLESS" ""
assert_eq "$PROFILE_OUT" "" "HDMI plugged into headless install → stays headless"
assert_eq "$RESTARTED" "no" "headless install + HDMI → no restart"
if [[ "$STDERR_OUT" == *"installed headless"* && "$STDERR_OUT" == *"re-run"* ]]; then
    echo "  PASS: headless install + HDMI → warning names the recovery"
    pass=$((pass + 1))
else
    echo "  FAIL: missing recovery warning (stderr: '$STDERR_OUT')"
    fail=$((fail + 1))
fi

run_case yes "" ""
assert_eq "$PROFILE_OUT" "" "no asound.conf at all + HDMI → stays headless"

run_case yes "$ASOUND_HEADLESS" "framebuffer"
assert_eq "$PROFILE_OUT" "" "stale framebuffer profile on headless audio path → reset to headless"

echo ""
if [[ "$fail" -gt 0 ]]; then
    echo "FAILED: $fail tests failed, $pass passed"
    exit 1
fi
echo "All $pass tests passed!"
