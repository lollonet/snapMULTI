---
type: decision
project: snapMULTI
date: 2026-04-27
status: accepted
pr: "#282"
tags: [decision, snapMULTI, snapcast, alsa, soundcard, mixer]
---

# DEC-006: Use `hw:CARD=NAME,DEV=0` for Headless Client SOUNDCARD

## Context

When `setup.sh` configures a headless client, it sets the snapclient's `SOUNDCARD` env var. This becomes `--soundcard <value>` to the snapclient binary, and snapcast 0.35.0 uses the same string for both PCM playback and mixer device derivation.

Two prior issues constrained the choice:
- **Pi Zero 2W headless**: snapclient 0.35.0 internally translates `default` to `sysdefault`, which alsa-lib resolves to card 0 — HDMI on Pi Zero 2W. Result: ALSA error 524 "no such device". So plain `default` is unusable for headless.
- **Display path**: when the client has a display, the asound.conf default-routes through `multi_out` (DAC + loopback) so the spectrum analyzer gets the audio. This requires `default`. Display path keeps `default`.

For headless, the natural fix was `hw:NAME,0` — direct hardware device, bypassing `default`/`sysdefault`. This worked for PCM but broke the mixer.

## Problem

snapcast 0.35.0 `client/player/alsa_player.cpp:67` derives the mixer card from the soundcard string:

```cpp
mixer_device_ = utils::string::split_left(settings_.pcm_device.name, ':', card);
if (!card.empty()) {
    auto pos = card.find("CARD=");
    if (pos != string::npos) {
        // extract card name, compute hw:N
    }
}
```

With `SOUNDCARD=hw:sndrpihifiberry,0`:
- split on `:` → `mixer_device_ = "hw"`, `card = "sndrpihifiberry,0"`
- `card.find("CARD=") = npos` → branch skipped
- `mixer_device_` stays `"hw"` — broken

Then `snd_mixer_attach(mixer_, "hw")` opens an empty mixer namespace, `snd_mixer_find_selem(sid="Digital")` returns NULL, snapclient terminates with "Failed to find mixer: Digital".

Observed live on moniaserver client (Pi 4, HiFiBerry DAC+ Standard, headless): snapclient crash loop.

## Decision

Use the ALSA-equivalent canonical form `hw:CARD=NAME,DEV=0` for headless client SOUNDCARD. Verified:
- `aplay -L` lists this exact string as the canonical name for the same device
- Snapcast extracts `CARD=NAME`, looks up `snd_card_get_index`, computes `mixer_device_ = "hw:<idx>"`, mixer attaches successfully
- Containing `CARD=` literal is what the parser needs

For HATs whose `audio-hats/*.conf` declares `HAT_MIXER="hardware:Digital"` (HiFiBerry DAC variants, IQAudio DAC/CODEC/DigiAMP, Allo Boss, JustBoom DAC, hifiberry-amp2, waveshare-wm8960), this restores hardware volume control on the PCM5122/WM8960/etc.

For HATs with `HAT_MIXER="software"` (USB audio, internal-audio, hifiberry-digi, justboom-digi, allo-digione, innomaker-dac-pro), the new soundcard form is also a valid PCM device — software mixer path unaffected.

## Why

- `hw:NAME,0` and `hw:CARD=NAME,DEV=0` are functionally identical at the ALSA level (verified via `aplay -L` and direct test)
- The longer form contains the literal `CARD=` substring snapcast 0.35.0's parser requires
- Avoids the Pi Zero 2W `default → sysdefault` translation issue (this is still an explicit `hw:` form)
- No fork of snapcast required

## Consequences

- HiFiBerry DAC+ variants and InnoMaker HIFI DAC HAT regain hardware mixer in headless mode
- Display-path clients unaffected (still use `default` for `multi_out` routing)
- Software-mixer HATs unaffected
- This is a workaround for an upstream snapcast quirk; if snapcast 0.36+ refactors `alsa_player.cpp:67` we can revisit, but the workaround is harmless

## Alternatives Considered

- **Patch snapcast** — would require maintaining a fork or upstreaming the fix; out of scope for our release
- **Use `hw:<index>,0`** — same parser issue, different failure mode (no `CARD=` literal)
- **Symlink `default` to the DAC card via asound.conf** — re-introduces the Pi Zero 2W `sysdefault` problem
- **Fall back to software mixer on headless** — loses hardware volume on PCM5122 (8-bit DSP, ~100 step → 207 step quality difference)

## Files Changed

- `client/common/scripts/setup.sh` — `SOUNDCARD_VALUE` for headless path

## Verification

Live test on moniaserver:
- Before: `[Error] (Alsa) Exception: Failed to find mixer: Digital, code: 0` → crash loop
- After (with `SOUNDCARD=hw:CARD=sndrpihifiberry,DEV=0`):
  ```
  [Info] (Player) Mixer mode: hardware, parameters: Digital
  [Info] (Alsa) PCM name: hw:CARD=sndrpihifiberry,DEV=0, sample rate: 44100 Hz
  ```
- Container stable, hardware Digital mixer attached.

Validated identical fix-then-deploy cycle on moniaclient, snapdigi, pizero (all PCM5122-based).

## Related

- [`client/common/scripts/setup.sh`](../../client/common/scripts/setup.sh) — where `SOUNDCARD` is assembled from HAT detection
