# snapMULTI — Project Instructions

## Documentation SSOT (Single Source of Truth)

Each topic has ONE authoritative document. Other files link to it — never duplicate content.
Italian translations (`*.it.md`) mirror the English docs and must stay in sync.

| Topic | Owner |
|-------|-------|
| Architecture, services, ports, audio sources, security model, mDNS overview, systemd units | `docs/USAGE.md` |
| Source config + parameter reference (inline comments) | `config/snapserver.conf` |
| Hardware, network, recommended setups | `docs/HARDWARE.md` |
| First-time install — flash → boot → listen, basic path only | `docs/INSTALL.md` |
| Multi-room, NFS/SMB library, custom `.env`, manual deploy, read-only fs, MPD CLI, JSON-RPC, update strategy | `docs/ADVANCED.md` |
| First-boot failures, mDNS troubleshooting, audio issues, container restart loops, diagnostic bundle recovery | `docs/TROUBLESHOOTING.md` |
| Value prop + quick start | `README.md` |
| Changelog | `CHANGELOG.md` |
| Quality gates (tools, paths, thresholds) | `CONTROL.yaml` |
| Client integration patterns (UI / displays / external controllers consuming metadata) | `docs/CLIENT-METADATA.md` |

**Rules:**
- README is an appliance manual — what it does, how to install, how to connect. No jargon. The "Quick start" section in README covers the 4-step onramp; the detailed walk-through lives in `docs/INSTALL.md`.
- New source type → update `config/snapserver.conf` + `docs/USAGE.md` "Audio Sources" table + `README.md` source table
- Source parameter changes → `config/snapserver.conf` only (it is the schema reference)
- Services/ports/security-model/architecture changes → `docs/USAGE.md` only
- Hardware/network changes → `docs/HARDWARE.md` only
- Install procedure (basic path) changes → `docs/INSTALL.md` only
- Operations / customisation / power-user how-tos → `docs/ADVANCED.md` only
- Failure-mode tables, recovery procedures → `docs/TROUBLESHOOTING.md` only
- README links to docs/ for anything technical — never inline technical details
- Quality gate changes → update `CONTROL.yaml` + CI workflow + pre-push hook together

## Deployment Targets

| Audience | Hardware | Method | Scripts |
|----------|----------|--------|---------|
| **Beginners** | Raspberry Pi 4 | Zero-touch SD | `prepare-sd.sh` → `firstboot.sh` → `deploy.sh`/`setup.sh` |
| **Advanced** | Pi4 or x86_64 | Automated or Manual | `deploy.sh` (optional) |

**Beginners**: No Linux administration required. Flash SD card on another computer, run `prepare-sd.sh` (or `prepare-sd.ps1` on Windows), choose what to install, insert in Pi, power on. HDMI shows a TUI progress display during installation (~10-15 min). The Pi becomes a dedicated audio appliance.

**Advanced**: Clone repo on any Linux host (Pi, x86_64, VM, NAS). Use `deploy.sh` for automation (hardware detection, directory setup, resource profiles) or skip it and just run `docker compose up`.

### Unified Installer

snapMULTI is a monorepo. The client (formerly `snapclient-pi`) lives at `client/`.

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
- Client: `/opt/snapclient/` — bridge networking (port 8081)
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
  client/                    # Audio player (formerly snapclient-pi repo)
  config/
    snapserver.conf          # Snapcast server config (5 active + 4 commented sources)
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
      entrypoint.sh          # Container entrypoint (ALSA config, speaker controller, metadata bridge)
      common.sh              # Configuration helpers (adapted from GioF71's wrapper)
      tidal-meta-bridge.sh   # Metadata scraper (tmux TUI → JSON file)
  docs/
    HARDWARE.md              # Hardware & network guide
    INSTALL.md               # First-time install (basic path)
    ADVANCED.md              # Operations & customisation (multi-room, NFS, manual deploy, etc.)
    TROUBLESHOOTING.md       # Failure modes + diagnostic bundle recovery
    USAGE.md                 # Architecture reference (services, ports, security, audio sources)
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
  Dockerfile.snapserver      # Snapserver + Snapweb (from badaix/snapcast, multi-stage)
  Dockerfile.shairport-sync  # AirPlay receiver (pipe output)
  Dockerfile.mpd             # MPD + ffmpeg (Alpine)
  Dockerfile.metadata        # Metadata service (Python 3.14, aiohttp + websockets)
  Dockerfile.tidal           # Tidal Connect (extends edgecrush3r base with ALSA plugins)
  docker-compose.yml         # 7 service definitions (6 core + tidal [ARM]), host networking
  .env.example               # Environment template
```

### Spotify Connect

Uses `ghcr.io/devgianlu/go-librespot` (Go reimplementation of Spotify Connect).

- **No custom Dockerfile** — uses upstream image directly, configured via `config/go-librespot.yml`
- **Audio routing**: Spotify app → go-librespot → pipe backend → `/audio/spotify_fifo` → snapserver
- **Metadata**: WebSocket API on port 24879 → `meta_go-librespot.py` (ships with Snapcast) → JSON-RPC to snapserver
- **Playback control**: Bidirectional — play/pause/next/seek from Snapcast clients back to Spotify
- **Device naming**: Uses hostname by default (e.g., "pi-server Spotify"). Override with `SPOTIFY_NAME` env var
- **Requires**: Spotify Premium (Connect is a Premium feature)
- **Architectures**: amd64 + arm64

### Tidal Connect

ARM-only audio source using `edgecrush3r/tidal-connect` as base image (Raspbian Stretch).

- **Dockerfile.tidal**: Extends base image with `libasound2-plugins` (ALSA FIFO routing), `ca-certificates` (TLS), and `tmux` (metadata scraping) from Debian Stretch archive. Base image is EOL Raspbian Stretch — packages come from `archive.debian.org`
- **Audio routing**: Tidal app → ALSA default device → `config/tidal-asound.conf` (rate converter + FIFO plugin) → `/audio/tidal_fifo` named pipe → snapserver
- **config/tidal-asound.conf**: speex rate converter (44100 Hz) → FIFO output. Validated by `deploy.sh` on ARM systems
- **Device naming**: Uses hostname by default (e.g., "pi-server Tidal"). Override with `TIDAL_NAME` env var
- **scripts/tidal/entrypoint.sh**: Sanitizes `FRIENDLY_NAME`, starts `speaker_controller_application` in tmux (for metadata), launches `tidal-meta-bridge.sh`, configures ALSA
- **scripts/tidal/common.sh**: Bind-mounted at `/common.sh` to override the image's baked-in copy. Writes ALSA config to `/tmp/asound.conf` (via `ALSA_CONFIG_PATH`) with system config include for read-only container support
- **scripts/tidal/tidal-meta-bridge.sh**: Runs inside tidal-connect container, scrapes tmux output from `speaker_controller_application` TUI, writes JSON to `/audio/tidal-metadata.json`
- **Metadata**: `speaker_controller_application` (ifi companion binary) displays track info in a curses TUI. `tidal-meta-bridge.sh` scrapes this via tmux → writes `/audio/tidal-metadata.json` → `meta_tidal.py` (in snapserver at `/usr/share/snapserver/plug-ins/`) polls the file and forwards to snapserver via JSON-RPC. No album art (TUI doesn't expose artwork URLs). May cause duplicate mDNS entry in Tidal app
- **Security**: Runs as root (proprietary binary), `read_only: true` with tmpfs at `/tmp` and `/config`, `cap_drop: ALL` + `DAC_OVERRIDE` (writes FIFOs owned by PUID)
- **Constraints**: ARM only (Pi 3/4/5), no x86_64 support. No OAuth — users cast from the Tidal mobile/desktop app

## Conventions

- **Docker images**: `lollonet/snapmulti-{server,airplay,mpd,metadata}:latest` (Docker Hub, built in CI) + `ghcr.io/devgianlu/go-librespot:v0.7.3` (upstream) + `lollonet/snapmulti-tidal:latest` (ARM only)
- **Multi-arch**: linux/amd64 (studio) + linux/arm64 (ci-runner-x86), native builds on self-hosted runners
- **Config paths**: all config in `config/`, all scripts in `scripts/`, shared libs in `scripts/common/`
- **Deployment**: tag push (`v*`) triggers build → manifest → deploy
- **Release gate**: every tag requires `device-smoke.sh --both` green on real Pi (ADR-005)
- **Git workflow**: always use PRs, never push directly to main unless explicitly requested
- **Audio format**: 44100:16:2 (44.1kHz, 16-bit, stereo) across all sources
- **CI gates**: shellcheck on all `scripts/**/*.sh`, docker-compose syntax, server+client bash tests
- **Debian support**: bookworm (primary) + trixie (Docker repo falls back to bookworm)
- **Console display**: ASCII-only for `/dev/tty1` output — PSF fonts lack Unicode symbols (✓▶○⠋). Use `[x]`/`[>]`/`[ ]` and `|/-\` spinner

## Non-goals

Explicitly out of scope — refuse scope-creep PRs that propose any of these without first opening an architectural discussion:

- **Custom Linux distribution.** Use Debian bookworm + cloud-init. No Buildroot, no Yocto, no custom OS.
- **Custom PCB / proprietary hardware.** Pi 3/4/5 + commodity HATs only.
- **Vendor cloud / hosted services.** No snapMULTI account system, telemetry endpoint, or hosted control plane. Everything runs on the user's LAN.
- **Unified UI replacing snapweb + myMPD + metadata-service.** The project federates existing tools; building a new web app is years of work with dubious ROI.
- **AI / voice assistants / DSP / spatial audio / room correction.** Audio enhancement belongs in the amp or a dedicated DSP upstream of snapMULTI.
- **Marketplace plugin system for sources.** Sources are pinned in `config/snapserver.conf` + `docker-compose.yml`. Adding a source is a deliberate architectural change, not user-configurable.
- **Multi-site / fleet enterprise orchestration.** snapMULTI is per-LAN. Multi-site = different product.
- **First-class support for boards outside Pi 3/4/5.** Rock 5 / Banana Pi M5 / x86 server are best-effort on the manual deploy path only — never wired into `prepare-sd.sh` or guaranteed by smoke gate.
- **Commercial support / SLA / paid licenses / CLA.** Project is GPL-3.0 community-maintained. No commercial offering, no contributor license agreement.

When a contributor proposes one of these, point to this section and ask for the underlying problem — there is usually a less-invasive way to solve it within scope.
