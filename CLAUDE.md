# CLAUDE.md — snapclient-pi

Raspberry Pi Snapcast client with auto-detection, Docker services, and framebuffer display.
**Requires snapMULTI server** — included as a git submodule at `client/` in the server repo.
Installation is handled by the server's `prepare-sd.sh` → `firstboot.sh` → client `setup.sh`.

## Architecture

```
common/
├── docker-compose.yml          # All services, profile: framebuffer
├── .env.example                # Full config reference
├── docker/
│   ├── snapclient/             # Core audio client (ALSA → Snapserver)
│   ├── audio-visualizer/       # FFT spectrum via WebSocket (port 8081)
│   └── fb-display/             # Framebuffer renderer (/dev/fb0)
├── scripts/
│   ├── setup.sh                # Main installer (--auto supported)
│   ├── discover-server.sh      # mDNS server discovery (boot-time)
│   ├── display.sh              # Display detection functions
│   ├── display-detect.sh       # Boot-time display profile reconciliation
│   └── ro-mode.sh              # Read-only filesystem management
├── public/                     # Web UI assets
└── audio-hats/                 # HAT overlay configs
install/snapclient.conf         # User-facing config defaults
```

## Key Rules

### mDNS Discovery
Use `_snapcast._tcp` (port 1704), **never** `_snapcast-ctrl._tcp`. RPC port = streaming_port + 1.

### Auto-Detection First
- Audio HAT: EEPROM at `/proc/device-tree/hat/product` → ALSA card names → I2C bus scan (detects chips without EEPROM: PCM5122 at 0x4C–0x4F, WM8960 at 0x1A, WM8804 at 0x3B) → USB fallback. Raw I2C fallback identifies compatible chip families, not always the exact board model.
- Snapserver: mDNS discovery, never hardcode IP
- Display resolution: `DISPLAY_RESOLUTION` env var optional; auto-detect from framebuffer, capped at 1920×1080

### Read-Only Filesystem
- Enabled by default (`ENABLE_READONLY=true`)
- Docker **must** use `fuse-overlayfs` storage driver — kernel overlay2 fails on overlayfs root
- `ro-mode.sh enable/disable/status` manages it; requires reboot
- Use `--no-readonly` flag on setup.sh to skip

### Display Detection
- `display-detect.sh` runs as a systemd oneshot at boot (`snapclient-display.service`)
- Checks for HDMI display, sets `COMPOSE_PROFILES=framebuffer` in `.env` if found (empty for headless)
- Reconciles running containers via `docker compose up -d --remove-orphans`
- Skips restart if profile unchanged; waits up to 30s for Docker daemon

### Display Rendering
- `fb_display.py` bind-mounted into container (live updates without image rebuild)
- Resolution scaling: renders at internal res, scales to actual FB on output
- Bottom bar: logo (left), date+time (center), volume knob (right)
- **Song Progress Bar**: elapsed/duration for file playback, uses local clock for smooth updates
- **Info panel**: source name, title, artist, album, format badge (codec/sample-rate/bit-depth)
- Timezone: mount `/etc/localtime` and `/etc/timezone` into container
- Install progress screen: `video=HDMI-A-1:800x600@60` in cmdline.txt (KMS ignores hdmi_group/hdmi_mode); remove after install

### Metadata (Centralized on Server)
- Metadata is served by the snapMULTI server (`metadata-service` container, ports 8082 WS + 8083 HTTP)
- Clients no longer run their own metadata-service or nginx containers
- fb-display connects to `METADATA_HOST:8082` (WS) and `METADATA_HOST:8083` (HTTP) for track info and artwork
- `METADATA_HOST` is derived from `SNAPSERVER_HOST` in docker-compose.yml (same server); defaults to `localhost`
- fb-display uses local clock between updates for smooth progress bar animation

### Spectrum Analyzer
- Third-octave default: 31 bands (ISO 266), 20 Hz–20 kHz
- Half-octave option: 21 bands, set `BAND_MODE=half-octave`
- Band count auto-detected by display from first WebSocket message

### Deployment
- **SD card**: Server's `prepare-sd.sh` copies client files to boot partition; server's `firstboot.sh` runs `setup.sh --auto`
- **Live update**: rsync changed files + `docker compose up -d --force-recreate`
- Bind-mounted files: `fb_display.py`, `visualizer.py` — no image rebuild needed

### Git & CI
- Pre-push hook runs shellcheck, bash syntax, HAT config validation
- Docker images: `lollonet/snapclient-pi[-*]:latest` (Docker Hub)
- Branch naming: `feature/<desc>` or `fix/<desc>`, always use PRs
