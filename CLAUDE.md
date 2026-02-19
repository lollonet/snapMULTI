# snapMULTI — Project Instructions

## Documentation SSOT (Single Source of Truth)

Each topic has ONE authoritative document. Other files link to it — never duplicate content.
Italian translations (`*.it.md`) mirror the English docs and must stay in sync.

| Topic | Owner |
|-------|-------|
| Audio sources, params, schema, JSON-RPC API | `docs/SOURCES.md` |
| Architecture, services, ports, mDNS, CI/CD | `docs/USAGE.md` |
| Hardware, network, recommended setups | `docs/HARDWARE.md` |
| User quickstart, client basic setup | `README.md` |
| Changelog | `CHANGELOG.md` |
| Source config (inline comments) | `config/snapserver.conf` |

**Rules:**
- README is an appliance manual — what it does, how to install, how to connect. No jargon.
- New source type → update `docs/SOURCES.md` + `config/snapserver.conf` + `README.md` source table
- Source param changes → `docs/SOURCES.md` only
- Services/ports/CI changes → `docs/USAGE.md` only
- Hardware/network changes → `docs/HARDWARE.md` only
- README links to docs/ for anything technical — never inline technical details

## Deployment Targets

| Audience | Hardware | Method | Scripts |
|----------|----------|--------|---------|
| **Beginners** | Raspberry Pi 4 | Zero-touch SD | `prepare-sd.sh` → `firstboot.sh` → `deploy.sh`/`setup.sh` |
| **Advanced** | Pi4 or x86_64 | Automated or Manual | `deploy.sh` (optional) |

**Beginners**: No terminal required. Flash SD card on another computer, run `prepare-sd.sh` (or `prepare-sd.ps1` on Windows), choose what to install, insert in Pi, power on. HDMI shows a TUI progress display during installation (~5-10 min). The Pi becomes a dedicated audio appliance.

**Advanced**: Clone repo on any Linux host (Pi, x86_64, VM, NAS). Use `deploy.sh` for automation (hardware detection, directory setup, resource profiles) or skip it and just run `docker compose up`.

### Unified Installer

snapMULTI is the umbrella project. The client repo (`rpi-snapclient-usb`) is included as a git submodule at `client/`.

`prepare-sd.sh` presents a 3-option menu:
1. **Audio Player** (client) — snapclient + optional cover art display
2. **Music Server** (server) — Spotify, AirPlay, MPD, Tidal, Snapcast
3. **Server + Player** (both) — both on the same Pi

The choice is written to `install.conf` on the SD card. `firstboot.sh` reads it and runs the appropriate installer(s).

### First-Boot Chain

`prepare-sd.sh` → cloud-init `runcmd` → `firstboot.sh` → `deploy.sh` / `setup.sh` → reboot

1. **prepare-sd.sh** (runs on host Mac/Linux/Windows): shows install menu, copies project files to boot partition, writes `install.conf`, sets 800x600 HDMI resolution, patches cloud-init `user-data`
2. **firstboot.sh** (runs on Pi as root): reads `install.conf`, sources `common/progress.sh` for TUI display, waits for network (with WiFi regulatory domain fix for 5 GHz DFS channels), installs git + Docker, runs `deploy.sh` (server) and/or `setup.sh --auto` (client), verifies containers healthy, reboots
3. **deploy.sh** (server): hardware detection, directory setup, `.env` generation, `docker compose pull && up`
4. **setup.sh** (client): audio HAT detection, ALSA config, Docker environment, image pull

### Headless Client Detection

For client installs, `firstboot.sh` detects whether an HDMI display is connected:
- **Display attached**: Full stack — snapclient + audio-visualizer + fb-display
- **Headless**: Audio only — snapclient container (no visual components)

Detection checks `/dev/fb0` and `/sys/class/drm/card*-HDMI-*/status`.

### Both Mode (Server + Player)

When both are installed on the same Pi:
- Server: `/opt/snapmulti/` — host networking (ports 1704, 1705, 1780, 6600, 8082, 8083, 8180)
- Client: `/opt/snapclient/` — bridge networking (ports 8080, 8081)
- Client auto-connects to `127.0.0.1` (local server)

### Progress Display (`scripts/common/progress.sh`)

Full-screen TUI on `/dev/tty1` (HDMI console), no-op when run via SSH.
- ASCII-safe characters only (Linux framebuffer PSF fonts lack Unicode symbols)
- Auto-detects HD screens (>1000px) and sets `Uni3-TerminusBold28x14` font
- Configurable step names and weights — caller sets `STEP_NAMES` and `STEP_WEIGHTS` arrays before sourcing
- `PROGRESS_TITLE` controls the header text (defaults to "snapMULTI Auto-Install")
- Background spinner animation with ease-out progress curve

## Project Structure

```
snapMULTI/
  client/                    # Git submodule: rpi-snapclient-usb (audio player)
  config/
    snapserver.conf          # Snapcast server config (4 active + 4 commented sources)
    mpd.conf                 # MPD config (FIFO + HTTP outputs)
    shairport-sync.conf      # shairport-sync pipe backend config
    tidal-asound.conf        # ALSA config for Tidal Connect FIFO output (ARM only)
    go-librespot.yml         # go-librespot config (pipe backend, WebSocket API, zeroconf)
  scripts/
    deploy.sh                # Server deployment (profiles, FIFO setup, validation)
    firstboot.sh             # Unified first-boot installer (reads install.conf)
    prepare-sd.sh            # Unified SD card prep (menu: client/server/both)
    prepare-sd.ps1           # Windows PowerShell equivalent of prepare-sd.sh
    airplay-entrypoint.sh    # AirPlay container entrypoint (DEVICE_NAME sanitization)
    common/                  # Shared shell libraries
      progress.sh            # TUI progress display for HDMI console (/dev/tty1)
      logging.sh             # Colored output functions (info, warn, error)
      sanitize.sh            # Input sanitization helpers
    tidal/                   # Tidal Connect entrypoint scripts
      entrypoint.sh          # Container entrypoint (ALSA config, FRIENDLY_NAME sanitization)
      common.sh              # Configuration helpers (adapted from GioF71's wrapper)
  docs/
    HARDWARE.md              # Hardware & network guide
    USAGE.md                 # Technical operations guide
    SOURCES.md               # Audio sources technical reference
    *.it.md                  # Italian translations
  .github/workflows/
    build-push.yml           # Dual-arch build + push to Docker Hub (5 images; Spotify uses upstream)
    deploy.yml               # SSH deploy (workflow_call, 7 containers)
    build-test.yml           # PR-only Docker build validation (5 Dockerfiles; Spotify uses upstream)
    validate.yml             # docker-compose syntax, shellcheck, env template
    claude-code-review.yml   # Automated PR review
    claude.yml               # Claude CI helper
  mympd/
    workdir/                 # myMPD persistent data
    cachedir/                # myMPD cache (album art, etc.)
  docker/
    metadata-service/
      metadata-service.py    # Server-side metadata + cover art service (WS:8082, HTTP:8083)
  install.conf.template      # Template for install type marker
  Dockerfile.snapserver      # Snapserver (from lollonet/santcasp, multi-stage)
  Dockerfile.shairport-sync  # AirPlay receiver (pipe output)
  Dockerfile.mpd             # MPD + ffmpeg (Alpine)
  Dockerfile.metadata        # Metadata service (Python 3.13, aiohttp + websockets)
  Dockerfile.tidal           # Tidal Connect (extends edgecrush3r base with ALSA plugins)
  docker-compose.yml         # 7 services (6 core + tidal-connect, host networking)
  .env.example               # Environment template
```

### Spotify Connect

Uses `ghcr.io/devgianlu/go-librespot` (Go reimplementation of Spotify Connect).

- **No custom Dockerfile** — uses upstream image directly, configured via `config/go-librespot.yml`
- **Audio routing**: Spotify app → go-librespot → pipe backend → `/audio/spotify_fifo` → snapserver
- **Metadata**: WebSocket API on port 24879 → `meta_go-librespot.py` (ships with Snapcast) → JSON-RPC to snapserver
- **Playback control**: Bidirectional — play/pause/next/seek from Snapcast clients back to Spotify
- **Device naming**: Uses hostname by default (e.g., "snapvideo Spotify"). Override with `SPOTIFY_NAME` env var
- **Requires**: Spotify Premium (Connect is a Premium feature)
- **Architectures**: amd64 + arm64

### Tidal Connect

ARM-only audio source using `edgecrush3r/tidal-connect` as base image (Raspbian Stretch).

- **Dockerfile.tidal**: Extends base image with `libasound2-plugins` from Debian Stretch archive (needed for ALSA FIFO routing). Base image is EOL Raspbian Stretch — packages come from `archive.raspbian.org`
- **Audio routing**: Tidal app → ALSA default device → `config/tidal-asound.conf` (rate converter + FIFO plugin) → `/audio/tidal` named pipe → snapserver
- **config/tidal-asound.conf**: speex rate converter (44100 Hz) → FIFO output. Validated by `deploy.sh` on ARM systems
- **Device naming**: Uses hostname by default (e.g., "snapvideo Tidal"). Override with `TIDAL_NAME` env var
- **scripts/tidal/entrypoint.sh**: Sanitizes `FRIENDLY_NAME`, disables `speaker_controller_application` (prevents duplicate mDNS entries), configures ALSA
- **Constraints**: ARM only (Pi 3/4/5), no x86_64 support. No OAuth — users cast from the Tidal mobile/desktop app

## Conventions

- **Docker images**: `lollonet/snapmulti-{server,airplay,mpd,metadata}:latest` (Docker Hub, built in CI) + `ghcr.io/devgianlu/go-librespot:v0.7.0` (upstream) + `lollonet/snapmulti-tidal:latest` (ARM only)
- **Multi-arch**: linux/amd64 (raspy) + linux/arm64 (studio), native builds on self-hosted runners
- **Config paths**: all config in `config/`, all scripts in `scripts/`, shared libs in `scripts/common/`
- **Deployment**: tag push (`v*`) triggers build → manifest → deploy
- **Git workflow**: always use PRs, never push directly to main unless explicitly requested
- **Audio format**: 44100:16:2 (44.1kHz, 16-bit, stereo) across all sources
- **CI gates**: shellcheck on all `scripts/**/*.sh`, docker-compose syntax validation
- **Debian support**: bookworm (primary) + trixie (Docker repo falls back to bookworm)
- **Console display**: ASCII-only for `/dev/tty1` output — PSF fonts lack Unicode symbols (✓▶○⠋). Use `[x]`/`[>]`/`[ ]` and `|/-\` spinner
