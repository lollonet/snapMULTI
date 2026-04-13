---
id: TECH-002
domain: technology
status: approved
source_of_truth: false
related: [REQ-001, REQ-002, REQ-003, REQ-010]
---

# TECH-002: Audio Components

## Audio Format

All audio streams use a consistent format:

| Parameter | Value | Reason |
|-----------|-------|--------|
| Sample Rate | 44100 Hz | CD quality, universal support |
| Bit Depth | 16-bit | Sufficient for home audio |
| Channels | 2 (stereo) | Standard stereo output |
| Codec | FLAC | Lossless, low latency |

## Component Versions

| Component | Version | Source |
|-----------|---------|--------|
| Snapcast | v0.35.0 (pinned) | badaix/snapcast upstream (Dockerfile.snapserver builds from pinned tag; santcasp fork available via workflow_dispatch) |
| MPD | 0.24.x | Alpine packages (Dockerfile.mpd) |
| go-librespot | v0.7.0 | Upstream image (ghcr.io/devgianlu/go-librespot) |
| Shairport-sync | 4.x | Built from source (Dockerfile.shairport-sync) |
| myMPD | latest | Official image (ghcr.io/jcorporation/mympd) |
| Tidal Connect | latest | ARM-only (edgecrush3r base + Dockerfile.tidal) |

## Snapcast Configuration

```
buffer = 2400      # 2.4 second buffer
chunk_ms = 40      # 40ms chunks
codec = flac       # Lossless codec
send_to_muted = false  # Save bandwidth
```

## MPD Configuration

```
audio_output {
    type "fifo"
    name "Snapcast"
    path "/audio/mpd_fifo"
    format "44100:16:2"
}
```

## go-librespot Features

- Spotify Connect protocol (Go reimplementation)
- 320kbps audio quality (OGG Vorbis)
- Pipe backend output to `/audio/spotify_fifo`
- WebSocket API on port 24879 for metadata
- Zeroconf device discovery (no stored credentials)
- Bidirectional playback control via Snapcast

## Shairport-sync Features

- AirPlay 1 protocol
- Pipe backend for Snapcast integration
- mDNS advertisement via Avahi
- Metadata support (cover art, track info)

## Tidal Connect Features

- Cast from Tidal app (mobile/desktop)
- ARM-only (Pi 3/4/5) — proprietary binary
- ALSA → speex rate converter → FIFO output
- Metadata via tmux TUI scraping (tidal-meta-bridge.sh)
- No album art (TUI limitation)
