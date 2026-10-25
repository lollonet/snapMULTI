#!/usr/bin/env bash
# Functional tests for the runtime ALSA card-id helpers in
# audio-hat-detect.sh: detect_internal_card_name, detect_usb_card_id and
# resolve_hat_card_name (shared by setup.sh and setup-zero2w.sh).
#
# Strategy: source audio-hat-detect.sh, then put an `aplay` stub at the
# front of PATH that prints canned `aplay -L` / `aplay -l` output for a
# given board, and assert the helpers return the ALSA card *id* (the
# value setup.sh writes as CARD=<id> / hw:<id>,0).
#
# Fixture shape follows real `aplay -L` output: PCM names such as
# `hw:CARD=vc4hdmi0,DEV=0` / `sysdefault:CARD=Headphones` followed by
# indented description lines. Bare card names never appear as whole
# lines, and `vc4-hdmi-0` appears only in descriptions (it is the card's
# display name, not its id). Lists are trimmed to the PCM kinds that
# matter for the parser; real output also has dmix/dsnoop/iec958/etc.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUDIO_HAT_DETECT="$SCRIPT_DIR/../common/scripts/audio-hat-detect.sh"

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

# ── Fixtures ─────────────────────────────────────────────────────
# The fixtures are consumed by a separate stub process via indirect
# export, which shellcheck cannot follow.
# shellcheck disable=SC2034
{
# Pi 4, Raspberry Pi OS Bookworm/Trixie (vc4-kms-v3d): analog jack via
# bcm2835 (card 0 "Headphones") + two KMS HDMI cards vc4hdmi0/vc4hdmi1.
FIXTURE_PI4_KMS_L=$(cat <<'EOF'
null
    Discard all samples (playback) or generate zero samples (capture)
hw:CARD=Headphones,DEV=0
    bcm2835 Headphones, bcm2835 Headphones
    Direct hardware device without any conversions
plughw:CARD=Headphones,DEV=0
    bcm2835 Headphones, bcm2835 Headphones
    Hardware device with all software conversions
default:CARD=Headphones
    bcm2835 Headphones, bcm2835 Headphones
    Default Audio Device
sysdefault:CARD=Headphones
    bcm2835 Headphones, bcm2835 Headphones
    Default Audio Device
dmix:CARD=Headphones,DEV=0
    bcm2835 Headphones, bcm2835 Headphones
    Direct sample mixing device
hw:CARD=vc4hdmi0,DEV=0
    vc4-hdmi-0, MAI PCM i2s-hifi-0
    Direct hardware device without any conversions
plughw:CARD=vc4hdmi0,DEV=0
    vc4-hdmi-0, MAI PCM i2s-hifi-0
    Hardware device with all software conversions
default:CARD=vc4hdmi0
    vc4-hdmi-0, MAI PCM i2s-hifi-0
    Default Audio Device
sysdefault:CARD=vc4hdmi0
    vc4-hdmi-0, MAI PCM i2s-hifi-0
    Default Audio Device
hdmi:CARD=vc4hdmi0,DEV=0
    vc4-hdmi-0, MAI PCM i2s-hifi-0
    HDMI Audio Output
hw:CARD=vc4hdmi1,DEV=0
    vc4-hdmi-1, MAI PCM i2s-hifi-0
    Direct hardware device without any conversions
plughw:CARD=vc4hdmi1,DEV=0
    vc4-hdmi-1, MAI PCM i2s-hifi-0
    Hardware device with all software conversions
sysdefault:CARD=vc4hdmi1
    vc4-hdmi-1, MAI PCM i2s-hifi-0
    Default Audio Device
hdmi:CARD=vc4hdmi1,DEV=0
    vc4-hdmi-1, MAI PCM i2s-hifi-0
    HDMI Audio Output
EOF
)
FIXTURE_PI4_KMS_l=$(cat <<'EOF'
**** List of PLAYBACK Hardware Devices ****
card 0: Headphones [bcm2835 Headphones], device 0: bcm2835 Headphones [bcm2835 Headphones]
  Subdevices: 8/8
  Subdevice #0: subdevice #0
card 1: vc4hdmi0 [vc4-hdmi-0], device 0: MAI PCM i2s-hifi-0 [MAI PCM i2s-hifi-0]
  Subdevices: 1/1
  Subdevice #0: subdevice #0
card 2: vc4hdmi1 [vc4-hdmi-1], device 0: MAI PCM i2s-hifi-0 [MAI PCM i2s-hifi-0]
  Subdevices: 1/1
  Subdevice #0: subdevice #0
EOF
)

# Pi 5, Bookworm/Trixie: no analog jack hardware, only the two KMS HDMI
# cards. mode=jack must fail so callers fall back to HDMI.
FIXTURE_PI5_L=$(cat <<'EOF'
null
    Discard all samples (playback) or generate zero samples (capture)
hw:CARD=vc4hdmi0,DEV=0
    vc4-hdmi-0, MAI PCM i2s-hifi-0
    Direct hardware device without any conversions
plughw:CARD=vc4hdmi0,DEV=0
    vc4-hdmi-0, MAI PCM i2s-hifi-0
    Hardware device with all software conversions
default:CARD=vc4hdmi0
    vc4-hdmi-0, MAI PCM i2s-hifi-0
    Default Audio Device
sysdefault:CARD=vc4hdmi0
    vc4-hdmi-0, MAI PCM i2s-hifi-0
    Default Audio Device
hdmi:CARD=vc4hdmi0,DEV=0
    vc4-hdmi-0, MAI PCM i2s-hifi-0
    HDMI Audio Output
hw:CARD=vc4hdmi1,DEV=0
    vc4-hdmi-1, MAI PCM i2s-hifi-0
    Direct hardware device without any conversions
sysdefault:CARD=vc4hdmi1
    vc4-hdmi-1, MAI PCM i2s-hifi-0
    Default Audio Device
EOF
)
FIXTURE_PI5_l=$(cat <<'EOF'
**** List of PLAYBACK Hardware Devices ****
card 0: vc4hdmi0 [vc4-hdmi-0], device 0: MAI PCM i2s-hifi-0 [MAI PCM i2s-hifi-0]
  Subdevices: 1/1
  Subdevice #0: subdevice #0
card 1: vc4hdmi1 [vc4-hdmi-1], device 0: MAI PCM i2s-hifi-0 [MAI PCM i2s-hifi-0]
  Subdevices: 1/1
  Subdevice #0: subdevice #0
EOF
)

# Pi 3, legacy bcm2835 audio (no KMS): HDMI is card "b1", jack "Headphones".
FIXTURE_PI3_LEGACY_L=$(cat <<'EOF'
null
    Discard all samples (playback) or generate zero samples (capture)
hw:CARD=b1,DEV=0
    bcm2835 HDMI 1, bcm2835 HDMI 1
    Direct hardware device without any conversions
plughw:CARD=b1,DEV=0
    bcm2835 HDMI 1, bcm2835 HDMI 1
    Hardware device with all software conversions
default:CARD=b1
    bcm2835 HDMI 1, bcm2835 HDMI 1
    Default Audio Device
sysdefault:CARD=b1
    bcm2835 HDMI 1, bcm2835 HDMI 1
    Default Audio Device
hw:CARD=Headphones,DEV=0
    bcm2835 Headphones, bcm2835 Headphones
    Direct hardware device without any conversions
plughw:CARD=Headphones,DEV=0
    bcm2835 Headphones, bcm2835 Headphones
    Hardware device with all software conversions
sysdefault:CARD=Headphones
    bcm2835 Headphones, bcm2835 Headphones
    Default Audio Device
EOF
)

# Pi Zero 2W, Bookworm/Trixie KMS: single HDMI card "vc4hdmi", no jack,
# plus a USB DAC whose card id is "Device" (not "USB").
FIXTURE_ZERO2W_USB_L=$(cat <<'EOF'
null
    Discard all samples (playback) or generate zero samples (capture)
hw:CARD=vc4hdmi,DEV=0
    vc4-hdmi, MAI PCM i2s-hifi-0
    Direct hardware device without any conversions
sysdefault:CARD=vc4hdmi
    vc4-hdmi, MAI PCM i2s-hifi-0
    Default Audio Device
hw:CARD=Device,DEV=0
    USB Audio Device, USB Audio
    Direct hardware device without any conversions
plughw:CARD=Device,DEV=0
    USB Audio Device, USB Audio
    Hardware device with all software conversions
sysdefault:CARD=Device
    USB Audio Device, USB Audio
    Default Audio Device
EOF
)
FIXTURE_ZERO2W_USB_l=$(cat <<'EOF'
**** List of PLAYBACK Hardware Devices ****
card 0: vc4hdmi [vc4-hdmi], device 0: MAI PCM i2s-hifi-0 [MAI PCM i2s-hifi-0]
  Subdevices: 1/1
  Subdevice #0: subdevice #0
card 1: Device [USB Audio Device], device 0: USB Audio [USB Audio]
  Subdevices: 1/1
  Subdevice #0: subdevice #0
EOF
)
}

# ── Source the helpers ───────────────────────────────────────────
# Top level of audio-hat-detect.sh is only function definitions.
# shellcheck source=../common/scripts/audio-hat-detect.sh
source "$AUDIO_HAT_DETECT"

for fn in detect_internal_card_name detect_usb_card_id resolve_hat_card_name; do
    if ! declare -F "$fn" >/dev/null; then
        echo "  FAIL: $fn not defined after sourcing $AUDIO_HAT_DETECT"
        exit 1
    fi
done

# Stub `aplay`: -L prints $<prefix>_L, -l prints $<prefix>_l (empty if unset).
STUB_DIR=$(mktemp -d)
trap 'rm -rf "$STUB_DIR"' EXIT
cat > "$STUB_DIR/aplay" <<'STUB'
#!/usr/bin/env bash
case "$1" in
    -L) var="${APLAY_FIXTURE}_L" ;;
    -l) var="${APLAY_FIXTURE}_l" ;;
    *)  exit 1 ;;
esac
printf '%s\n' "${!var:-}"
STUB
chmod +x "$STUB_DIR/aplay"
ORIG_PATH="$PATH"

use_board() {
    local prefix="$1" v
    for v in "${prefix}_L" "${prefix}_l"; do
        # shellcheck disable=SC2163  # intentional: export by name
        [[ -n "${!v:-}" ]] && export "$v"
    done
    export APLAY_FIXTURE="$prefix"
    PATH="$STUB_DIR:$ORIG_PATH"
    unset USB_CARD_ID
}

echo "=== Pi 4 KMS (Headphones + vc4hdmi0/1) ==="
use_board FIXTURE_PI4_KMS
assert_eq "$(detect_internal_card_name hdmi)" "vc4hdmi0" "hdmi → vc4hdmi0 (card id, not display name vc4-hdmi-0)"
assert_eq "$(detect_internal_card_name jack)" "Headphones" "jack → Headphones"
assert_eq "$(resolve_hat_card_name internal-audio Headphones jack 2>/dev/null)" "Headphones" "resolve jack → Headphones"
assert_eq "$(resolve_hat_card_name internal-audio Headphones hdmi 2>/dev/null)" "vc4hdmi0" "resolve hdmi → vc4hdmi0"
assert_eq "$(resolve_hat_card_name internal-audio Headphones "" 2>/dev/null)" "Headphones" "resolve empty mode → jack first"
assert_eq "$(detect_usb_card_id || echo none)" "none" "no USB card → detect_usb_card_id fails"
assert_eq "$(resolve_hat_card_name usb-audio USB 2>/dev/null)" "USB" "usb-audio without a USB card keeps profile default"

echo
echo "=== Pi 5 (vc4hdmi0/1 only, no jack) ==="
use_board FIXTURE_PI5
assert_eq "$(detect_internal_card_name hdmi)" "vc4hdmi0" "hdmi → vc4hdmi0"
jack_out=$(detect_internal_card_name jack 2>/dev/null || true)
assert_eq "$jack_out" "" "jack → empty (no Headphones card)"
if detect_internal_card_name jack >/dev/null 2>&1; then
    echo "  FAIL: jack should exit non-zero on Pi 5"
    fail=$((fail + 1))
else
    echo "  PASS: jack returns non-zero exit (signals fallback)"
    pass=$((pass + 1))
fi
assert_eq "$(resolve_hat_card_name internal-audio Headphones jack 2>/dev/null)" "vc4hdmi0" "resolve jack falls back to HDMI"
assert_eq "$(resolve_hat_card_name internal-audio Headphones "" 2>/dev/null)" "vc4hdmi0" "resolve empty mode falls back to HDMI"
warn_out=$(resolve_hat_card_name internal-audio Headphones jack 2>&1 >/dev/null)
if [[ "$warn_out" == *"Falling back to HDMI"* ]]; then
    echo "  PASS: jack→HDMI fallback is logged on stderr"
    pass=$((pass + 1))
else
    echo "  FAIL: jack→HDMI fallback not logged (stderr: '$warn_out')"
    fail=$((fail + 1))
fi

echo
echo "=== Pi 3 legacy bcm2835 (b1 + Headphones) ==="
use_board FIXTURE_PI3_LEGACY
assert_eq "$(detect_internal_card_name hdmi)" "b1" "hdmi → b1"
assert_eq "$(detect_internal_card_name jack)" "Headphones" "jack → Headphones"

echo
echo "=== Pi Zero 2W KMS + USB DAC (vc4hdmi + Device) ==="
use_board FIXTURE_ZERO2W_USB
assert_eq "$(detect_internal_card_name hdmi)" "vc4hdmi" "hdmi → vc4hdmi"
assert_eq "$(resolve_hat_card_name internal-audio Headphones "" 2>/dev/null)" "vc4hdmi" "internal-audio on Zero 2W → HDMI, never Headphones"
assert_eq "$(detect_usb_card_id)" "Device" "USB card id probed from aplay -l"
assert_eq "$(resolve_hat_card_name usb-audio USB 2>/dev/null)" "Device" "usb-audio → probed id 'Device', not 'USB'"
export USB_CARD_ID="S2"
assert_eq "$(resolve_hat_card_name usb-audio USB 2>/dev/null)" "S2" "usb-audio honours exported USB_CARD_ID"
unset USB_CARD_ID
assert_eq "$(resolve_hat_card_name hifiberry-dac sndrpihifiberry 2>/dev/null)" "sndrpihifiberry" "other profiles pass through unchanged"

echo
echo "=== Defensive ==="
use_board FIXTURE_PI4_KMS
if detect_internal_card_name garbage 2>/dev/null; then
    echo "  FAIL: invalid mode should exit non-zero"
    fail=$((fail + 1))
else
    echo "  PASS: invalid mode rejected"
    pass=$((pass + 1))
fi
if (detect_internal_card_name 2>/dev/null); then
    echo "  FAIL: missing arg should exit non-zero"
    fail=$((fail + 1))
else
    echo "  PASS: missing arg rejected"
    pass=$((pass + 1))
fi
assert_eq "$(resolve_hat_card_name internal-audio Headphones bogus 2>/dev/null)" "Headphones" "unknown mode keeps default"
result=$(PATH=/nonexistent detect_internal_card_name hdmi 2>/dev/null || true)
assert_eq "$result" "" "aplay missing → empty output"
if (PATH=/nonexistent detect_internal_card_name hdmi 2>/dev/null); then
    echo "  FAIL: aplay missing should exit non-zero"
    fail=$((fail + 1))
else
    echo "  PASS: aplay missing returns non-zero (signals fallback to caller)"
    pass=$((pass + 1))
fi
assert_eq "$(PATH=/nonexistent resolve_hat_card_name internal-audio Headphones jack 2>/dev/null)" "Headphones" "aplay missing → resolve keeps default"

echo
echo "=== Callers wired to the shared helper ==="
ZERO2W_SH="$SCRIPT_DIR/../common/scripts/setup-zero2w.sh"
SETUP_SH="$SCRIPT_DIR/../common/scripts/setup.sh"
if grep -qE 'HAT_CARD_NAME=\$\(resolve_hat_card_name "\$_hat_config" "\$HAT_CARD_NAME" "\$AUDIO_INTERNAL_OUTPUT"\)' "$ZERO2W_SH"; then
    echo "  PASS: setup-zero2w.sh resolves the card id via resolve_hat_card_name (USB_CARD_ID / HDMI)"
    pass=$((pass + 1))
else
    echo "  FAIL: setup-zero2w.sh does not call resolve_hat_card_name"
    fail=$((fail + 1))
fi
if grep -qF 'SOUNDCARD="plughw:CARD=${HAT_CARD_NAME},DEV=0"' "$ZERO2W_SH"; then
    echo "  PASS: setup-zero2w.sh passes plughw:CARD=<id>,DEV=0 to snapclient"
    pass=$((pass + 1))
else
    echo "  FAIL: setup-zero2w.sh SOUNDCARD is not plughw:CARD=<id>,DEV=0"
    fail=$((fail + 1))
fi
if grep -qE 'HAT_CARD_NAME=\$\(resolve_hat_card_name internal-audio' "$SETUP_SH"; then
    echo "  PASS: setup.sh resolves internal-audio via resolve_hat_card_name"
    pass=$((pass + 1))
else
    echo "  FAIL: setup.sh does not call resolve_hat_card_name for internal-audio"
    fail=$((fail + 1))
fi
if grep -qF 'SOUNDCARD_VALUE="plughw:CARD=${HAT_CARD_NAME:-Headphones},DEV=0"' "$SETUP_SH"; then
    echo "  PASS: setup.sh headless SOUNDCARD uses plughw (format/rate conversion)"
    pass=$((pass + 1))
else
    echo "  FAIL: setup.sh headless SOUNDCARD is not plughw:CARD=<id>,DEV=0"
    fail=$((fail + 1))
fi

echo
echo "Results: $pass passed, $fail failed"
exit $(( fail > 0 ? 1 : 0 ))
