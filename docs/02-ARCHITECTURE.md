# Architecture

## System Context

```
                        ┌─────────────────────────┐
                        │    snapMULTI Server     │
                        │                         │
                        │  Snapserver (1704/1705) │
                        │  Metadata  (8082/8083)  │
                        └─────┬──────────┬────────┘
                              │          │
                     TCP:1704 │          │ WS:8082 + HTTP:8083
                              │          │
┌─────────────────────────────┼──────────┼────────────────────────┐
│  snapclient-pi         │          │                        │
│                             ▼          ▼                        │
│  ┌──────────────┐   ┌──────────────┐   ┌──────────────────────┐ │
│  │  snapclient  │   │  fb-display  │   │  audio-visualizer    │ │
│  │              │   │              │◀──│  (WS:8081, local)    │ │
│  │  ALSA out ───┼──▶│  /dev/fb0    │   │                      │ │
│  │  + loopback  │   │  cover art   │   │  ALSA loopback ──▶   │ │
│  │              │   │  spectrum    │   │  FFT → dBFS bands    │ │
│  └──────────────┘   └──────────────┘   └──────────────────────┘ │
└─────────────────────────────────────────────────────────────────┘
```

## Container Architecture

### Service Dependency Chain

```
snapclient (healthy) → audio-visualizer (healthy) → fb-display
```

All three are Docker containers managed by `docker-compose.yml`. fb-display is optional (profile: `framebuffer`).

### Container Details

| Container | Image | Network | Devices | User |
|-----------|-------|---------|---------|------|
| snapclient | `lollonet/snapclient-pi:latest` | host | `/dev/snd` | 1000:1000 + audio(29) |
| audio-visualizer | `lollonet/snapclient-pi-visualizer:latest` | bridge (8081 localhost) | `/dev/snd` | 1000:1000 + audio(29) |
| fb-display | `lollonet/snapclient-pi-fb-display:latest` | host | `/dev/fb0` | 1000:1000 + video(44) |

### Audio Data Flow

```
Snapserver ──TCP:1704──▶ snapclient ──▶ ALSA multi_out
                                            │
                                    ┌───────┴───────┐
                                    ▼               ▼
                              DAC (speakers)   Loopback,0,0
                                                    │
                                              Loopback,1,0
                                                    │
                                                    ▼
                                          audio-visualizer
                                           (S16_LE capture)
                                                    │
                                              FFT → dBFS
                                                    │
                                              WS:8081 push
                                                    │
                                                    ▼
                                              fb-display
                                           (spectrum bars)
```

### Metadata Data Flow

```
snapMULTI metadata-service (centralized)
        │
        ├──WS:8082──▶ fb-display subscribes with CLIENT_ID
        │              receives: title, artist, album, duration,
        │                        elapsed, playing, codec,
        │                        sample_rate, bit_depth, source,
        │                        artwork, volume, muted
        │              also receives: server_info (server_version)
        │
        └──HTTP:8083─▶ fb-display fetches cover art
                       endpoint: /artwork/<filename>
```

### ALSA Configuration

The `multi_out` ALSA plugin routes stereo audio to both the DAC and the loopback device simultaneously:

```
pcm.multi_out {
    type multi
    slaves {
        a { pcm "hw:<DAC>" channels 2 }
        b { pcm "hw:Loopback,0,0" channels 2 }
    }
}

pcm.!default {
    type plug
    slave { pcm "multi_out" channels 4 }
    ttable { 0.0 1  1.1 1  0.2 1  1.3 1 }
}
```

Snapclient outputs to `default`, which fans out to both slaves via the transfer table.

## File Layout

```
common/
├── docker-compose.yml          # Service definitions, profiles, resource limits
├── .env.example                # All configuration with defaults and comments
├── docker/
│   ├── snapclient/
│   │   ├── Dockerfile          # Alpine + snapclient binary
│   │   └── entrypoint.sh       # ALSA config, server discovery, snapclient launch
│   ├── audio-visualizer/
│   │   ├── Dockerfile          # Python 3.13-slim + numpy + websockets
│   │   └── visualizer.py       # ALSA capture → FFT → WebSocket broadcast
│   └── fb-display/
│       ├── Dockerfile          # Python 3.13-slim + numpy + pillow + websockets
│       ├── fb_display.py       # Metadata + spectrum → framebuffer render
│       ├── logo.png            # SnapForge logo for bottom bar
│       └── snapforge-text.png  # SnapForge text logo
├── scripts/
│   ├── setup.sh                # Main installer (interactive + --auto)
│   ├── discover-server.sh      # mDNS discovery on boot (systemd)
│   ├── display.sh              # Display detection functions
│   ├── display-detect.sh       # Boot-time display profile reconciliation
│   └── ro-mode.sh              # Read-only filesystem management
├── audio-hats/                 # 17 HAT configuration files
│   └── <hat-name>.conf         # HAT_OVERLAY, HAT_CARD, HAT_RATE per HAT
└── public/                     # Web UI assets (standby artwork, etc.)

install/
└── snapclient.conf             # User-facing config defaults
```

## Key Design Decisions

### Why Docker?
- Consistent environment across Pi models
- Pre-built images avoid compiling on Pi (slow, fragile)
- Resource limits per container prevent OOM
- Healthchecks and restart policies for reliability

### Why Direct Framebuffer?
- No X11/Wayland overhead — renders directly to `/dev/fb0`
- Minimal memory footprint (~50MB for display)
- Works headless or with any HDMI display
- Pixel-perfect control for spectrum bars and album art

### Why ALSA Loopback?
- Captures audio without modifying the playback path
- Zero latency penalty on the audio output
- Kernel module, no userspace audio routing complexity

### Why Centralized Metadata?
- Single metadata-service on the server handles all source types (MPD, Spotify, AirPlay, Tidal)
- Clients just subscribe — no source-specific logic needed
- Cover art cached once on server, served to all clients via HTTP
- Eliminates N clients making N redundant API calls
