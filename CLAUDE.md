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
| **Beginners** | Raspberry Pi 4 | Zero-touch SD | `prepare-sd.sh` → `firstboot.sh` → `deploy.sh` |
| **Advanced** | Pi4 or x86_64 | Automated or Manual | `deploy.sh` (optional) |

**Beginners**: No terminal required. Flash SD card on another computer, run `prepare-sd.sh`, insert in Pi, power on. HDMI shows a TUI progress display during installation (~5-10 min). The Pi becomes a dedicated audio appliance.

**Advanced**: Clone repo on any Linux host (Pi, x86_64, VM, NAS). Use `deploy.sh` for automation (hardware detection, directory setup, resource profiles) or skip it and just run `docker compose up`.

### First-Boot Chain

`prepare-sd.sh` → cloud-init `runcmd` → `firstboot.sh` → `deploy.sh` → reboot

1. **prepare-sd.sh** (runs on host Mac/Linux): copies project files to boot partition, sets 800x600 HDMI resolution in `cmdline.txt`, patches cloud-init `user-data` to chain `firstboot.sh`
2. **firstboot.sh** (runs on Pi as root): sources `common/progress.sh` for TUI display, waits for network (with WiFi regulatory domain fix for 5 GHz DFS channels), installs Docker, runs `deploy.sh`, verifies containers healthy, reboots
3. **deploy.sh** (runs on Pi): hardware detection, directory setup, `.env` generation, `docker compose pull && up`

### Progress Display (`scripts/common/progress.sh`)

Full-screen TUI on `/dev/tty1` (HDMI console), no-op when run via SSH.
- ASCII-safe characters only (Linux framebuffer PSF fonts lack Unicode symbols)
- Auto-detects HD screens (>1000px) and sets `Uni3-TerminusBold28x14` font
- 5 weighted steps: Network (5%), Copy files (2%), Docker (35%), Deploy (50%), Verify (8%)
- Background spinner animation with ease-out progress curve

## Project Structure

```
snapMULTI/
  config/
    snapserver.conf          # Snapcast server config (4 active + 4 commented sources)
    mpd.conf                 # MPD config (FIFO + HTTP outputs)
    shairport-sync.conf      # shairport-sync pipe backend config
    tidal-asound.conf        # ALSA config for Tidal Connect FIFO output (ARM only)
    go-librespot.yml         # go-librespot config (pipe backend, WebSocket API, zeroconf)
  scripts/
    deploy.sh                # Server deployment (profiles, FIFO setup, validation)
    firstboot.sh             # First-boot provisioning (TUI progress, WiFi kick, Docker install)
    airplay-entrypoint.sh    # AirPlay container entrypoint (DEVICE_NAME sanitization)
    prepare-sd.sh            # SD card preparation (file copy, 800x600 resolution, boot patching)
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
    build-push.yml           # Dual-arch build + push to ghcr.io (3 images; Spotify uses upstream)
    deploy.yml               # SSH deploy (workflow_call, 6 containers)
    build-test.yml           # PR-only Docker build validation (3 Dockerfiles; Spotify uses upstream)
    validate.yml             # docker-compose syntax, shellcheck, env template
    claude-code-review.yml   # Automated PR review
    claude.yml               # Claude CI helper
  mympd/
    workdir/                 # myMPD persistent data
    cachedir/                # myMPD cache (album art, etc.)
  Dockerfile.snapserver      # Snapserver (from lollonet/santcasp, multi-stage)
  Dockerfile.shairport-sync  # AirPlay receiver (pipe output)
  Dockerfile.mpd             # MPD + ffmpeg (Alpine)
  Dockerfile.tidal           # Tidal Connect (extends edgecrush3r base with ALSA plugins)
  docker-compose.yml         # 6 services (5 core + tidal-connect, host networking)
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

- **Docker images**: `ghcr.io/lollonet/snapmulti-{server,airplay,mpd}:latest` (built in CI) + `ghcr.io/devgianlu/go-librespot:v0.7.0` (upstream) + `ghcr.io/lollonet/snapmulti-tidal:latest` (ARM only)
- **Multi-arch**: linux/amd64 (raspy) + linux/arm64 (studio), native builds on self-hosted runners
- **Config paths**: all config in `config/`, all scripts in `scripts/`, shared libs in `scripts/common/`
- **Deployment**: tag push (`v*`) triggers build → manifest → deploy
- **Git workflow**: always use PRs, never push directly to main unless explicitly requested
- **Audio format**: 44100:16:2 (44.1kHz, 16-bit, stereo) across all sources
- **CI gates**: shellcheck on all `scripts/**/*.sh`, docker-compose syntax validation
- **Debian support**: bookworm (primary) + trixie (Docker repo falls back to bookworm)
- **Console display**: ASCII-only for `/dev/tty1` output — PSF fonts lack Unicode symbols (✓▶○⠋). Use `[x]`/`[>]`/`[ ]` and `|/-\` spinner
