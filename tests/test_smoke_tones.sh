#!/usr/bin/env bash
# Static checks for the acoustic smoke-tone feature.
#
# Verifies: WAV files exist + are valid RIFF/WAV with expected format;
# play-smoke-tone.sh has the safety/suppression rules; device-smoke.sh
# wires the --tone flag; install_boot_tune_service installs WAVs +
# helper to the right paths; SD-prep staging lists the new files.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
AUDIO_DIR="$ROOT/scripts/common/audio"

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

echo "## WAV file inventory + format"

for result in pass warn fail skip; do
    f="$AUDIO_DIR/smoke-$result.wav"
    assert "[[ -f '$f' ]]" "$result: WAV exists at scripts/common/audio/"
    if [[ -f "$f" ]]; then
        # RIFF/WAV magic — first 4 bytes 'RIFF', bytes 8-11 'WAVE'
        magic=$(head -c 4 "$f" 2>/dev/null)
        wave=$(head -c 12 "$f" 2>/dev/null | tail -c 4)
        assert "[[ '$magic' == 'RIFF' ]]" "$result: RIFF header present"
        assert "[[ '$wave' == 'WAVE' ]]" "$result: WAVE format marker present"
        # Size sanity: 4-60 KB range (~100 ms to ~1.5 s at 22050 mono 16-bit)
        size=$(stat -f%z "$f" 2>/dev/null || stat -c%s "$f" 2>/dev/null)
        assert "[[ '$size' -ge 3000 && '$size' -le 65000 ]]" \
            "$result: size $size bytes within expected 3-60 KB range"
    fi
done

echo
echo "## play-smoke-tone.sh helper"

HELPER="$ROOT/scripts/common/play-smoke-tone.sh"
assert "[[ -f '$HELPER' ]]" "helper exists"
assert "[[ -x '$HELPER' ]]" "helper is executable"
assert "head -1 '$HELPER' | grep -q '^#!/usr/bin/env bash'" "shebang is /usr/bin/env bash"
assert "grep -q 'set -uo pipefail' '$HELPER'" "set -uo pipefail present (note: no -e — best-effort never blocks)"
assert "grep -q 'aplay -q' '$HELPER'" "uses aplay -q for playback"
assert "grep -q 'TEST_TONE=false' '$HELPER' || grep -q 'TEST_TONE=' '$HELPER'" \
    "honours TEST_TONE flag from install.conf"
assert "grep -q 'SNAPMULTI_BOOT_SMOKE_TONES' '$HELPER'" \
    "respects SNAPMULTI_BOOT_SMOKE_TONES=off opt-out"
assert "grep -q 'Server.GetStatus' '$HELPER'" \
    "checks Snapcast active-stream before playing (don't talk over music)"
assert "grep -q 'exit 0' '$HELPER'" "always exits 0 (best-effort, never blocks)"
assert "grep -q '_resolve_dac_card' '$HELPER'" \
    "resolves physical DAC card to bypass broken default chain"
assert "grep -qE 'Loopback|vc4hdmi' '$HELPER'" \
    "DAC resolver skips Loopback / vc4hdmi virtual cards"
assert "grep -q 'plughw:CARD=' '$HELPER'" \
    "uses explicit -D plughw:CARD=<id> for resolved DAC"

echo
echo "## install-deps.sh — libasound2-plugins for both/client roles"

DEPS="$ROOT/scripts/common/install-deps.sh"
assert "grep -q 'libasound2-plugins' '$DEPS'" \
    "libasound2-plugins in apt deps list (rate converters for non-native sample rates)"

echo
echo "## device-smoke.sh --tone wiring"

SMOKE="$ROOT/scripts/device-smoke.sh"
assert "grep -qE '^\s*TONE=false\s*$' '$SMOKE'" "TONE default is false (opt-in flag)"
assert "grep -qE 'while.*--tone' '$SMOKE' || grep -qE '\-\-tone\)' '$SMOKE'" \
    "--tone CLI flag parsed"
assert "grep -q '_play_tone' '$SMOKE'" "_play_tone helper function defined"
assert "grep -q '_play_tone pass' '$SMOKE'" "plays pass tone on success without warnings"
assert "grep -q '_play_tone warn' '$SMOKE'" "plays warn tone on warnings"
assert "grep -q '_play_tone fail' '$SMOKE'" "plays fail tone on failure"
assert "grep -q 'snapmulti-play-smoke-tone' '$SMOKE'" \
    "tone helper resolved via /usr/local/bin/snapmulti-play-smoke-tone fallback"

echo
echo "## install_boot_tune_service installs audio files"

SYSTUNE="$ROOT/scripts/common/system-tune.sh"
assert "grep -qE 'install -d.*\/usr\/share\/snapmulti\/audio' '$SYSTUNE'" \
    "creates /usr/share/snapmulti/audio/ install dir"
assert "grep -q 'install -m 644' '$SYSTUNE' && grep -q 'smoke-\\*\\.wav' '$SYSTUNE'" \
    "installs WAV files with mode 644 (loop over smoke-*.wav glob)"
assert "grep -q 'snapmulti-play-smoke-tone' '$SYSTUNE'" \
    "installs play-smoke-tone.sh helper to /usr/local/bin/"
assert "grep -qE 'BASH_SOURCE\[0\]' '$SYSTUNE'" \
    "resolves audio source via \${BASH_SOURCE[0]} (works for both server + client install paths)"

echo
echo "## SD-prep staging lists the new files"

PREPARE_SH="$ROOT/scripts/prepare-sd.sh"
PREPARE_PS1="$ROOT/scripts/prepare-sd.ps1"
assert "grep -q 'common/play-smoke-tone.sh' '$PREPARE_SH'" \
    "prepare-sd.sh verify-list includes play-smoke-tone.sh"
assert "grep -q 'common/audio/smoke-pass.wav' '$PREPARE_SH'" \
    "prepare-sd.sh verify-list includes smoke-pass.wav"
assert "grep -q 'common/audio/smoke-fail.wav' '$PREPARE_SH'" \
    "prepare-sd.sh verify-list includes smoke-fail.wav"
assert "grep -q \"'common/play-smoke-tone.sh'\" '$PREPARE_PS1'" \
    "prepare-sd.ps1 verify-list includes play-smoke-tone.sh"
assert "grep -q \"'common/audio/smoke-pass.wav'\" '$PREPARE_PS1'" \
    "prepare-sd.ps1 verify-list includes smoke-pass.wav"

echo
echo "## dev tool for regenerating tones"

REGEN="$ROOT/scripts/dev/regenerate-smoke-tones.sh"
assert "[[ -x '$REGEN' ]]" "dev regenerator exists + is executable"
assert "grep -q 'command -v sox' '$REGEN'" "checks for sox dependency"
assert "grep -qE 'synth.*sine' '$REGEN'" "uses sox synth sine for tone generation"

echo
echo "## Summary"
echo "  Passed: $pass"
echo "  Failed: $fail"

[[ $fail -eq 0 ]]
