# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed
- **Tidal Connect replaces tidal-bridge** — Native casting from Tidal app instead of CLI-based streaming
  - Uses `giof71/tidal-connect` image with ALSA→FIFO routing
  - ARM only (Pi 3/4/5), x86_64 not supported
  - No OAuth login required — just cast from app
- **Removed TCP-Input source** — Replaced by Tidal source in snapserver config

### Removed
- **Dockerfile.tidal** — No longer building custom tidal image
- **scripts/tidal-bridge.py** — Replaced by tidal-connect container
- **tidal directory** — No longer needed for session storage

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
