#!/usr/bin/env bash
# Regenerate the 4 smoke result WAVs in scripts/common/audio/. Requires sox.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUDIO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)/common/audio"

if ! command -v sox >/dev/null 2>&1; then
    echo "ERROR: sox not installed. Install with 'brew install sox' or 'apt install sox'." >&2
    exit 1
fi

mkdir -p "$AUDIO_DIR"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# 44100 = PCM5122 native rate, no ALSA rate conversion needed.
RATE=44100
CHANNELS=1
BITS=16

# 5 ms attack + 5 ms release fade on every segment to avoid click/pop.
gen_tone() {
    local out="$1" duration="$2" freq="$3"
    sox -n -r "$RATE" -c "$CHANNELS" -b "$BITS" "$out" \
        synth "$duration" sine "$freq" \
        fade q 0.005 "$duration" 0.005 \
        gain -h -3 2>/dev/null
}

# PASS — ascending C5 → E5 → G5 (major triad), 150 ms each, gapless
gen_tone "$WORK/c5.wav" 0.15 523
gen_tone "$WORK/e5.wav" 0.15 659
gen_tone "$WORK/g5.wav" 0.15 784
sox "$WORK/c5.wav" "$WORK/e5.wav" "$WORK/g5.wav" "$AUDIO_DIR/smoke-pass.wav"

# WARN — alternating A4 ↔ C5, 200 ms each, 2 cycles (~800 ms total)
gen_tone "$WORK/a4w.wav" 0.20 440
gen_tone "$WORK/c5w.wav" 0.20 523
sox "$WORK/a4w.wav" "$WORK/c5w.wav" "$WORK/a4w.wav" "$WORK/c5w.wav" \
    "$AUDIO_DIR/smoke-warn.wav"

# FAIL — descending tritone A4 → D♯4 (311 Hz), 300 ms each, 2 cycles (~1.2 s)
gen_tone "$WORK/a4f.wav" 0.30 440
gen_tone "$WORK/d4f.wav" 0.30 311
sox "$WORK/a4f.wav" "$WORK/d4f.wav" "$WORK/a4f.wav" "$WORK/d4f.wav" \
    "$AUDIO_DIR/smoke-fail.wav"

# SKIP — single low chirp, 220 Hz, 100 ms (subtle "not ready yet")
gen_tone "$AUDIO_DIR/smoke-skip.wav" 0.10 220

echo "Generated:"
for f in pass warn fail skip; do
    p="$AUDIO_DIR/smoke-$f.wav"
    size=$(stat -f%z "$p" 2>/dev/null || stat -c%s "$p" 2>/dev/null)
    duration=$(sox --i -D "$p" 2>/dev/null)
    printf "  %-25s  %s bytes  %.3f s\n" "smoke-$f.wav" "$size" "$duration"
done
