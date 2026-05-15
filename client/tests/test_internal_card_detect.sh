#!/usr/bin/env bash
# Functional tests for detect_internal_card_name in audio-hat-detect.sh.
#
# Strategy: source audio-hat-detect.sh, then shadow `aplay` with a function
# that returns canned `aplay -L` output (Pi 3/4/5 variants — sourced from
# Raspberry Pi official documentation and the Bookworm release notes).
# Then assert that the helper returns the right card name for each (mode,
# Pi) combination, and the right fall-back behaviour on Pi 5.
#
# The fixtures below are STATIC SNAPSHOTS of real `aplay -L` output —
# they're not synthesised. If upstream renames a card, this test breaks
# and tells us which fixture needs updating.

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
# Pi 3/4 on legacy kernel — bcm2835_alsa with combined HDMI+Headphones.
# Headphones lives on its own card; HDMI is the bare "HDMI" alias.
# Disables below acknowledge that shellcheck can't see the indirect
# reference inside shadow_aplay's stub script (the variable is consumed
# via `eval export <name>` and then read by a separate bash process).
# shellcheck disable=SC2034
FIXTURE_PI4_LEGACY=$(cat <<'EOF'
null
    Discard all samples (playback) or generate zero samples (capture)
default
sysdefault:CARD=Headphones
    bcm2835 Headphones, bcm2835 Headphones
Headphones
    bcm2835 Headphones, bcm2835 Headphones
    Default Audio Device
HDMI
    bcm2835 HDMI 1, bcm2835 HDMI 1
    Default Audio Device
EOF
)

# Pi 4 on Bookworm — KMS driver renames HDMI to vc4-hdmi-0 / vc4-hdmi-1.
# Headphones still present (analog jack hardware unchanged on Pi 4).
# shellcheck disable=SC2034
FIXTURE_PI4_BOOKWORM=$(cat <<'EOF'
null
    Discard all samples (playback) or generate zero samples (capture)
default
sysdefault:CARD=vc4hdmi0
    vc4-hdmi-0, MAI PCM vc4-hdmi-0-0
    Default Audio Device
vc4-hdmi-0
    vc4-hdmi-0, MAI PCM vc4-hdmi-0-0
    Direct hardware device without any conversions
vc4-hdmi-1
    vc4-hdmi-1, MAI PCM vc4-hdmi-1-0
    Direct hardware device without any conversions
Headphones
    bcm2835 Headphones, bcm2835 Headphones
    Default Audio Device
EOF
)

# Pi 5 on Bookworm — analog jack hardware REMOVED, only HDMI outputs.
# No Headphones card. helper must return empty for mode=jack so the
# setup.sh fallback chain promotes to hdmi.
# shellcheck disable=SC2034
FIXTURE_PI5_BOOKWORM=$(cat <<'EOF'
null
    Discard all samples (playback) or generate zero samples (capture)
default
sysdefault:CARD=vc4hdmi0
    vc4-hdmi-0, MAI PCM vc4-hdmi-0-0
    Default Audio Device
vc4-hdmi-0
    vc4-hdmi-0, MAI PCM vc4-hdmi-0-0
    Direct hardware device without any conversions
vc4-hdmi-1
    vc4-hdmi-1, MAI PCM vc4-hdmi-1-0
    Direct hardware device without any conversions
EOF
)

# ── Source the helper ────────────────────────────────────────────
# We need only the function; sourcing the whole file is safe because the
# top-level is just function definitions + a guarded interactive prompt
# (run only when sourced from setup.sh's manual HAT-selection path,
# which we don't trip here).
# shellcheck source=../common/scripts/audio-hat-detect.sh
source "$AUDIO_HAT_DETECT"

if ! declare -F detect_internal_card_name >/dev/null; then
    echo "  FAIL: detect_internal_card_name not defined after sourcing $AUDIO_HAT_DETECT"
    exit 1
fi

# Helper: install an aplay() shell function that emits one of the fixtures.
# detect_internal_card_name resolves aplay via `command -v` and then calls
# the resulting path directly. We shadow the resolution by exporting a
# function named `aplay` AND putting a stub at the top of PATH.
shadow_aplay() {
    local fixture_var="$1"
    local stub_dir
    stub_dir=$(mktemp -d /tmp/aplay-stub-XXXXXX)
    cat > "$stub_dir/aplay" <<STUB
#!/usr/bin/env bash
case "\$1" in
    -L) printf '%s\n' "\${${fixture_var}}" ;;
    *) exit 1 ;;
esac
STUB
    chmod +x "$stub_dir/aplay"
    PATH="$stub_dir:$PATH"
    export PATH
    # Export the named fixture so the stub script (separate process) sees it.
    # shellcheck disable=SC2086,SC2163  # intentional: indirect export by name
    eval "export $fixture_var"
    _APLAY_STUB_DIR="$stub_dir"
}

unshadow_aplay() {
    [[ -n "${_APLAY_STUB_DIR:-}" ]] && rm -rf "$_APLAY_STUB_DIR"
    unset _APLAY_STUB_DIR
    PATH=$(echo "$PATH" | tr ':' '\n' | grep -v '^/tmp/aplay-stub-' | tr '\n' ':' | sed 's/:$//')
    export PATH
}

echo "=== Pi 4 legacy kernel (bcm2835_alsa) ==="
shadow_aplay FIXTURE_PI4_LEGACY
assert_eq "$(detect_internal_card_name hdmi)" "HDMI" "Pi 4 legacy: hdmi → bare 'HDMI' card"
assert_eq "$(detect_internal_card_name jack)" "Headphones" "Pi 4 legacy: jack → 'Headphones'"
unshadow_aplay

echo
echo "=== Pi 4 Bookworm (KMS vc4-hdmi-X) ==="
shadow_aplay FIXTURE_PI4_BOOKWORM
assert_eq "$(detect_internal_card_name hdmi)" "vc4-hdmi-0" "Pi 4 Bookworm: hdmi → 'vc4-hdmi-0' (first match)"
assert_eq "$(detect_internal_card_name jack)" "Headphones" "Pi 4 Bookworm: jack → 'Headphones' (analog still present)"
unshadow_aplay

echo
echo "=== Pi 5 Bookworm (no analog jack) ==="
shadow_aplay FIXTURE_PI5_BOOKWORM
assert_eq "$(detect_internal_card_name hdmi)" "vc4-hdmi-0" "Pi 5: hdmi → 'vc4-hdmi-0'"
# Critical: jack must FAIL on Pi 5 — helper returns empty + exit 1, so the
# setup.sh caller can detect this and fall back to hdmi. We capture stdout
# and exit code separately.
jack_out=$(detect_internal_card_name jack 2>/dev/null || true)
assert_eq "$jack_out" "" "Pi 5: jack → empty (no Headphones card)"
if detect_internal_card_name jack 2>/dev/null; then
    echo "  FAIL: Pi 5 jack should exit non-zero"
    fail=$((fail + 1))
else
    echo "  PASS: Pi 5 jack returns non-zero exit (signals fallback)"
    pass=$((pass + 1))
fi
unshadow_aplay

echo
echo "=== Defensive: invalid mode ==="
shadow_aplay FIXTURE_PI4_BOOKWORM
if detect_internal_card_name garbage 2>/dev/null; then
    echo "  FAIL: invalid mode should exit non-zero"
    fail=$((fail + 1))
else
    echo "  PASS: invalid mode rejected"
    pass=$((pass + 1))
fi
# Missing arg — `${1:?...}` should trigger
if (detect_internal_card_name 2>/dev/null); then
    echo "  FAIL: missing arg should exit non-zero"
    fail=$((fail + 1))
else
    echo "  PASS: missing arg rejected"
    pass=$((pass + 1))
fi
unshadow_aplay

echo
echo "=== Defensive: aplay unavailable ==="
# Force the function to fail by stripping PATH so `command -v aplay` returns
# nothing. Subshell so we don't break later cleanup.
result=$(PATH=/nonexistent detect_internal_card_name hdmi 2>/dev/null || true)
assert_eq "$result" "" "aplay missing → empty output"
if (PATH=/nonexistent detect_internal_card_name hdmi 2>/dev/null); then
    echo "  FAIL: aplay missing should exit non-zero"
    fail=$((fail + 1))
else
    echo "  PASS: aplay missing returns non-zero (signals fallback to caller)"
    pass=$((pass + 1))
fi

echo
echo "Results: $pass passed, $fail failed"
exit $(( fail > 0 ? 1 : 0 ))
