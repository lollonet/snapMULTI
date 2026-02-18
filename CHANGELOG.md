# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- **Unified installer** — Single `prepare-sd.sh` supports both server and client installation
  - 3-option menu: Audio Player (client), Music Server (server), Server + Player (both)
  - `install.conf` marker controls what `firstboot.sh` installs on the Pi
  - Client repo (`rpi-snapclient-usb`) added as git submodule at `client/`
- **Windows SD card preparation** — `prepare-sd.ps1` PowerShell script with same functionality as `prepare-sd.sh`
  - Auto-detects bootfs drive, 3-option menu, patches cloud-init, safe eject
- **Git installed on Pi** — `deploy.sh` and `firstboot.sh` install `git` so users can `git pull` for updates
- **Headless client detection** — `firstboot.sh` detects HDMI via `/dev/fb0` and DRM status files
  - Display attached: full visual stack (snapclient + visualizer + cover art display)
  - Headless: audio-only (snapclient container only)
- **Both mode** — Server + Player on the same Pi with no port conflicts
  - Server at `/opt/snapmulti/` (host networking), client at `/opt/snapclient/` (bridge networking)
  - Client auto-connects to `127.0.0.1`
- **Configurable progress display** — `progress.sh` now accepts `STEP_NAMES`, `STEP_WEIGHTS`, and `PROGRESS_TITLE` from caller instead of hardcoded values
- **Progress display TUI** ([#58](https://github.com/lollonet/snapMULTI/pull/58)) — Full-screen progress display on HDMI console (`/dev/tty1`) during first-boot installation
  - ASCII progress bar, step checklist (`[x]` done, `[>]` current, `[ ]` pending), animated spinner
  - Live log output area showing last 8 lines of install progress
  - Elapsed time tracking using monotonic clock (handles wrong system time on first boot)
  - Weighted step percentages reflecting actual duration of each phase
  - Console-safe characters only (no Unicode symbols that break on Linux framebuffer)
- **HD screen font auto-detection** — Detects framebuffer > 1000px and switches to `Uni3-TerminusBold28x14` for readability on 1080p displays
- **Setup resolution** — `prepare-sd.sh` sets temporary 800x600 via `cmdline.txt` `video=` parameter for consistent TUI layout
- **Monitoring tools** — `deploy.sh` installs `sysstat` (sar), `iotop-c`, and `dstat` for system monitoring
- **Dependabot** — Weekly automated dependency update PRs for Docker images and GitHub Actions

### Changed
- **Docker daemon config ownership** — `deploy.sh` now exclusively owns `/etc/docker/daemon.json` (live-restore, log rotation) with python3 merge logic for existing configs; `firstboot.sh` no longer writes it to avoid conflicts
- **firstboot.sh Docker install** — Uses official APT repository instead of `get.docker.com` convenience script for reproducible, auditable installs
- **Spotify Connect: switch to go-librespot** ([#59](https://github.com/lollonet/snapMULTI/pull/59)) — Replaced Rust librespot v0.8.0 with go-librespot for Spotify Connect
  - Full metadata support: track name, artist, album, cover art forwarded to Snapcast clients
  - Bidirectional playback control: play/pause/next/previous/seek from any Snapcast client
  - Uses Snapcast's official `meta_go-librespot.py` plugin (maintained upstream)
  - Uses official `ghcr.io/devgianlu/go-librespot:v0.7.0` Docker image (no custom build needed)
  - Removed `Dockerfile.librespot` and `patches/librespot-ipv4-fallback.patch`
  - New config file: `config/go-librespot.yml` (pipe backend, WebSocket API on port 24879)

### Fixed
- **Spotify FIFO ENXIO** ([#62](https://github.com/lollonet/snapMULTI/pull/62)) — go-librespot opens the FIFO with `O_NONBLOCK` only at playback start; if snapserver has no active writer it closes the read end, causing `ENXIO`. Fix holds the FIFO open in read-write mode (`exec 3<>`) before starting go-librespot
- **firstboot.sh 5 GHz WiFi on first boot** — On Debian trixie, `brcmfmac` ignores the kernel `cfg80211.ieee80211_regdom` parameter, blocking auto-connect on 5 GHz DFS channels (e.g., channel 100). Fix applies regulatory domain via `iw reg set` and explicitly activates WiFi via `nmcli` after 30s timeout
- **firstboot.sh DNS readiness** — Network check now verifies DNS resolution (`getent hosts deb.debian.org`) in addition to ping; prevents `apt-get` failure when ping succeeds but DNS lags behind on first boot
- **firstboot.sh network timeout** — Increased from 2 to 3 minutes for first-boot WiFi scenarios
- **progress.sh line_count bug** — Fixed `grep -c || echo 0` producing `"0\n0"` which broke arithmetic in the output area padding loop

### Security
- **Audio directory permissions** — Tightened from 777/666 to 750/660 on audio directory and FIFOs

### Maintenance
- **CI: actions/checkout v4 → v6** ([#61](https://github.com/lollonet/snapMULTI/pull/61)) — Node.js 24 runtime, improved credential persistence
- **CI: appleboy/ssh-action 1.0.0 → 1.2.5** ([#60](https://github.com/lollonet/snapMULTI/pull/60)) — Bug fixes and improved error handling

## [0.1.5] — 2026-02-17

### Changed
- **Tidal device naming** — Device name now uses hostname instead of hardcoded "snapMULTI"
  - Container reads `/etc/hostname` from host for dynamic naming (e.g., "snapdigi Tidal")
  - Set `TIDAL_NAME` env var to override
- **prepare-sd.sh** — Auto-unmounts SD card after preparation (macOS + Linux)

### Fixed
- **Tidal Connect ALSA plugins** — Base image missing `libasound2-plugins` for FIFO output
  - Created `Dockerfile.tidal` extending base image with ALSA plugins
  - Audio now correctly routes through FIFO to snapserver
  - Built from Debian Stretch archive (base image uses EOL Raspbian Stretch)
- **Tidal duplicate devices** — Disabled `speaker_controller_application` which was advertising a second mDNS entry
- **Tidal speedy playback** — Added speex rate converter to `tidal-asound.conf` for proper 44.1kHz resampling
- **firstboot.sh Debian trixie support** — Docker repo fallback to bookworm for unsupported Debian releases (trixie, sid)
- **firstboot.sh missing common scripts** — Now copies `scripts/common/` directory needed by deploy.sh
- **deploy.sh tidal-asound.conf validation** — Added to required config check on ARM systems
- **prepare-sd.sh hostname placeholder** — Instructions now show `<your-hostname>` instead of hardcoded name

## [0.1.4] — 2026-02-12

### Breaking Changes
- **TCP Input source removed** — Source 2 (tcp://0.0.0.0:4953) replaced by Tidal Connect. If you were using TCP input for custom ffmpeg streams, add it back to `config/snapserver.conf`:
  ```ini
  source = tcp://0.0.0.0:4953?name=TCP-Input&mode=server
  ```

### Changed
- **Tidal Connect replaces tidal-bridge** — Native casting from Tidal app instead of CLI-based streaming
  - Uses `edgecrush3r/tidal-connect` as base with custom ALSA→FIFO routing
  - ARM only (Pi 3/4/5), x86_64 not supported
  - No OAuth login required — just cast from app
- **Shared logging utilities** — `scripts/common/logging.sh` provides colored output functions used by deploy.sh
- **meta_mpd.py refactor** — Split `_update_properties()` into focused helper methods for better maintainability

### Removed
- **scripts/tidal-bridge.py** — Replaced by tidal-connect container
- **tidal directory** — No longer needed for session storage

### Security
- **Tidal script hardening** — Removed unsafe `eval`, added shell safety settings (`set -euo pipefail`)
- **Input sanitization** — Extended to `model_name` in addition to `friendly_name`, removed risky apostrophe from allowed chars
- **Python venv** — Snapserver uses virtual environment instead of `--break-system-packages`
- **CI deploy** — Parameterized GHCR username via `github.repository_owner`

## [0.1.3] — 2026-02-11

### Changed
- **Tidal service enabled by default** — No longer requires `--profile tidal` flag

### Fixed
- **Script execute permissions** — deploy.sh ensures all scripts are executable after clone
- **airplay-entrypoint.sh mode** — Fixed missing execute permission in git

## [0.1.2] — 2026-02-11

### Added
- **AirPlay metadata support** — meta_shairport.py reads shairport-sync metadata pipe and forwards to snapserver
- **Cover art server** — HTTP server on port 5858 serves album art with client-reachable IP detection
- **COVER_ART_HOST env var** — Explicit override for cover art URL hostname

### Changed
- **meta_shairport.py rewrite** — Single-threaded select() event loop instead of daemon threads (more reliable as controlscript)
- **shairport-sync entrypoint** — Added `-M` flag to enable metadata output

### Fixed
- **Metadata pipe creation** — deploy.sh now creates `/audio/shairport-metadata` FIFO
- **Cover art IP resolution** — Uses actual host IP instead of container hostname (works across network)
- **AirPlay duration parsing** — Binary metadata fields (`astm`, `PICT`) now correctly decoded as bytes instead of UTF-8

## [0.1.1] — 2026-02-09

### Added
- **deploy.sh Avahi installation** — Automatically installs and enables `avahi-daemon` for mDNS discovery (required for Spotify Connect and AirPlay visibility)
- **Documentation: Audio format & network mode** — Explains 44100:16:2 sample rate, FLAC codec, and why host networking is required for mDNS
- **Documentation: Troubleshooting guide** — Common issues table in README with solutions for Spotify/AirPlay visibility, audio sync, and connection problems
- **Documentation: Logs & diagnostics** — Container logs, common error messages, health checks, and installation log location
- **Documentation: Upgrade instructions** — Standard update, backup, and rollback procedures

### Changed
- **Dockerfiles** — Pin Alpine base image to `3.23` for reproducible builds
- **Documentation: Quick Start reorganization** — Split into Beginners (Pi zero-touch) and Advanced (any Linux) sections with clear audience targeting
- **CLAUDE.md** — Added Deployment Targets section, updated project structure
- **CI/CD: validate.yml** — Added shellcheck linting for all scripts/ with `-S warning` severity
- **Service naming** — AirPlay and Spotify use hostname-based names with optional `AIRPLAY_NAME`/`SPOTIFY_NAME` env vars for customization
- **deploy.sh validation** — Config file validation, PROJECT_ROOT check, and `--profile` argument validation with safe `shift` handling
- **deploy.sh service verification** — Retry loop (6 attempts x 10s) instead of fixed sleep for slow-starting services
- **firstboot.sh container verification** — Healthcheck-based loop (12 attempts x 10s) replaces naive `sleep 5` + container count
- **firstboot.sh network check** — Detects default gateway each iteration, falls back to 1.1.1.1 and 8.8.8.8 (works behind restrictive firewalls)
- **Snapserver log level** — Changed from `info` to `warning` to reduce log noise from constant resync messages

### Fixed
- **MPD first-run startup** — Pre-create empty `mpd.db` file; auto-detect network mounts and set `MPD_START_PERIOD` to 5 min (NFS) or 30s (local)
- **myMPD startup** — Uses extended `MPD_START_PERIOD` for healthcheck, waits for MPD healthy before starting
- **deploy.sh validate_config** — Change to PROJECT_ROOT before running `docker compose config` (fixes first-run failures when script invoked from a different directory)
- **prepare-sd.sh** — Support Bookworm cloud-init user-data and rpi-snapclient-usb boot pattern
- **firstboot.sh directory structure** — Create `scripts/` subdirectory expected by deploy.sh
- **firstboot.sh healthcheck grep** — Fix `(unhealthy)` containers being counted as healthy due to substring match
- **deploy.sh profile update** — Use BEGIN/END block markers instead of deleting to EOF (preserves user custom env vars)
- **deploy.sh consolidated** — Merged root `deploy.sh` into `scripts/deploy.sh` (single script with Docker install, hardware detection, music library scan, resource profiles)
- **MPD log noise** — Set `log_level "notice"` to reduce ffmpeg warnings for macOS resource fork files
- **Snapserver mDNS hostname** — Configure `http.host` to use container hostname for proper client discovery
- **Snapserver duplicate mDNS** — Disable `publish_http` to prevent dual "Snapcast" / "Snapcast Server" announcements
- **meta_mpd.py JSON bug** — Patch upstream bug where `type()` wrapper caused "Object of type type is not JSON serializable" error, breaking cover art and metadata

### Security
- **DEVICE_NAME sanitization** — Entrypoint script strips shell metacharacters to prevent command injection ([#40](https://github.com/lollonet/snapMULTI/pull/40))
- **FIFO permissions** — Changed from 666 (world-writable) to 660 (owner+group only)
- **PATH hardening** — Secure PATH export in firstboot.sh prevents hijacking
- **Docker install** — Uses official APT repository with GPG verification instead of `curl | sh`

## [0.1.0] — 2026-02-04

Initial release. Multiroom audio server with five audio sources, security hardening, hardware auto-detection, and zero-touch deployment.

### Fixed

- **Zero-touch boot freeze** — Fixed prepare-sd.sh overwriting Pi Imager's firstrun.sh, which broke WiFi configuration and caused boot to hang at "Waiting for network..."

### Features

- **Multiroom audio** — Snapcast server with synchronized playback across all clients
- **Five audio sources**:
  - MPD (local music library)
  - AirPlay (via shairport-sync)
  - Spotify Connect (via librespot)
  - TCP input (port 4953 for external streams)
  - Tidal streaming (via tidalapi, HiFi subscription required)
- **myMPD web GUI** — Mobile-ready interface on port 8180
- **mDNS autodiscovery** — Automatic client discovery via Avahi/Bonjour
- **Security hardening** — read_only containers, no-new-privileges, cap_drop ALL, tmpfs mounts
- **Hardware auto-detection** — Auto-selects resource profile (minimal/standard/performance) based on RAM and Pi model
- **Zero-touch SD preparation** — `scripts/prepare-sd.sh` for automatic first-boot installation
- **Deploy script** — `scripts/deploy.sh` bootstraps fresh Linux machines
- **Multi-arch images** — amd64 + arm64 on ghcr.io
- **Bilingual docs** — English + Italian

### Technical

- Audio format: 44100:16:2 (CD quality)
- Container architecture: 5 separate services communicating via named pipes
- CI/CD: GitHub Actions with self-hosted runners
- Resource profiles: minimal (Pi Zero 2/Pi 3), standard (Pi 4 2GB), performance (Pi 4 4GB+/Pi 5)
