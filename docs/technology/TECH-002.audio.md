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
| Snapcast | 0.34.1 | lollonet/santcasp fork |
| MPD | 0.24.x | Alpine packages |
| Librespot | latest | Built from source |
| Shairport-sync | 4.x | Built from source |
| myMPD | latest | Official image |

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
    path "/audio/snapcast_fifo"
    format "44100:16:2"
}
```

## Librespot Features

- Spotify Connect protocol
- 320kbps audio quality
- Volume normalization support
- D-Bus integration for metadata

## Shairport-sync Features

- AirPlay 1 protocol
- Pipe backend for Snapcast integration
- mDNS advertisement via Avahi
- Metadata support (cover art, track info)
