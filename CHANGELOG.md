# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- **Documentation: Audio format & network mode** — Explains 44100:16:2 sample rate, FLAC codec, and why host networking is required for mDNS
- **Documentation: Troubleshooting guide** — Common issues table in README with solutions for Spotify/AirPlay visibility, audio sync, and connection problems
- **Documentation: Logs & diagnostics** — How to view container logs, common error messages, health checks, and installation log location
- **Documentation: Upgrade instructions** — Standard update, backup, and rollback procedures

### Changed
- **Service naming** — AirPlay and Spotify now use hostname-based names (`hostname AirPlay`, `hostname Spotify`) with optional `AIRPLAY_NAME`/`SPOTIFY_NAME` env vars for customization
- **firstboot.sh security** — Added PATH hardening to prevent PATH hijacking attacks
- **firstboot.sh error handling** — Added failed marker, network timeout check, secure Docker install via APT repo (not curl|sh), and container verification
- **deploy.sh validation** — Added config file validation before start and PROJECT_ROOT existence check
- **deploy.sh service verification** — Retry loop (6 attempts × 10s) instead of fixed 10s sleep for slow-starting services

### Fixed
- **Zero-touch SD card** — Rewrote prepare-sd.sh using rpi-snapclient-usb pattern; now patches firstrun.sh instead of overwriting it
- **Bookworm support** — prepare-sd.sh now supports both Bullseye (firstrun.sh) and Bookworm (cloud-init user-data)
- **Directory structure** — firstboot.sh creates correct `scripts/` subdirectory that deploy.sh expects

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
