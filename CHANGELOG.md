# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- **Deploy script** — `deploy.sh` bootstraps a fresh Linux machine (Raspberry Pi or x86_64) as a snapMULTI server: installs Docker, creates directories, auto-detects timezone/user, pulls images, starts services
- **MPD metadata support** ([#17](https://github.com/lollonet/snapMULTI/pull/17)) — Now-playing info (title, artist, album, cover art) pushed to clients via `meta_mpd.py` controlscript; adds Python runtime and plugins to snapserver image

### Changed
- **CI/CD temporarily amd64-only** ([#16](https://github.com/lollonet/snapMULTI/pull/16)) — Disable arm64 build while studio-runner is unavailable; `docs/USAGE.md` updated to reflect temporary state

### Fixed
- **Documentation accuracy** ([#18](https://github.com/lollonet/snapMULTI/pull/18)) — Corrected Docker image names in storage tables, added missing MPD ports (6600, 8000) to network tables and firewall rules, fixed MPD music directory description, updated snapclient examples to use official image with host networking, added controlscript parameter to pipe source schema

## [1.2.2] — 2026-02-02

### Fixed
- **D-Bus access denied** — Add `apparmor:unconfined` security option to shairport-sync and librespot containers; AppArmor blocks D-Bus socket access by default
- **librespot IPv6 bind failure** — Patch librespot discovery server (`server.rs`) to fall back to IPv4 when IPv6 is unavailable (`ipv6.disable=1` hosts)
- **snapserver CI build** — Strip `-santcasp` suffix from CMake project version; `project(VERSION 0.34.1-santcasp)` is invalid CMake syntax (only numeric components allowed)

## [1.2.1] — 2026-02-02

### Fixed
- **AirPlay mDNS discovery** ([#15](https://github.com/lollonet/snapMULTI/pull/15)) — Mount host D-Bus socket for shairport-sync so it can reach the host's Avahi daemon for AirPlay advertisement
- **Spotify Connect discovery** ([#15](https://github.com/lollonet/snapMULTI/pull/15)) — Rebuild librespot from source with Avahi Zeroconf backend (`with-avahi`) instead of Alpine package; the default `libmdns` backend requires IPv6 sockets, which fails on hosts with `ipv6.disable=1`

## [1.2.0] — 2026-02-01

### Added
- **myMPD web GUI** ([#11](https://github.com/lollonet/snapMULTI/pull/11)) — Mobile-ready web interface for MPD control via [myMPD](https://github.com/jcorporation/myMPD) on port 8180 (PWA, album art, playlists)

### Changed
- **Container architecture** ([#13](https://github.com/lollonet/snapMULTI/pull/13)) — Split monolith image into separate containers: snapserver (from [santcasp](https://github.com/lollonet/santcasp)), shairport-sync (AirPlay), and librespot (Spotify Connect), communicating via named pipes in shared `/audio` volume
- **Snapserver source** — Built from `lollonet/santcasp` fork instead of `badaix/snapcast`
- **Audio sources** — AirPlay and Spotify sources changed from process-managed (`airplay://`, `librespot://`) to pipe-based (`pipe://`) for inter-container communication
- **CI/CD pipeline** — Now builds 4 images (snapmulti-server, snapmulti-airplay, snapmulti-spotify, snapmulti-mpd) and deploys 5 containers

### Fixed
- **myMPD deploy** ([#12](https://github.com/lollonet/snapMULTI/pull/12)) — Include myMPD in deploy workflow (pull + start + create directories)

### Removed
- **Monolith image** — `Dockerfile.snapMULTI` replaced by `Dockerfile.snapserver`, `Dockerfile.shairport-sync`, and `Dockerfile.librespot`

## [1.0.0] — 2026-01-30

First stable release. Multiroom audio server with four audio sources, multi-arch Docker images, full bilingual documentation (EN + IT).

### Added
- **Initial Docker setup** — Snapcast server and MPD running in Alpine Linux containers with CI/CD pipelines
- **MPD configuration** — Music Player Daemon with FIFO output to Snapcast
- **mDNS autodiscovery** ([#1](https://github.com/lollonet/snapMULTI/pull/1)) — Automatic client discovery via Avahi/Bonjour using host D-Bus socket
- **Multi-source audio** — Four audio sources: MPD (local library), TCP input (port 4953), AirPlay (via shairport-sync), and Spotify Connect (via librespot)
- **Spotify Connect** ([#2](https://github.com/lollonet/snapMULTI/issues/2)) — Fourth audio source via librespot (Spotify Premium required, 320 kbps)
- **Container registry** ([#3](https://github.com/lollonet/snapMULTI/issues/3)) — Multi-arch images (amd64 + arm64) built natively on self-hosted runners and pushed to ghcr.io
- **Audio sources reference** — `docs/SOURCES.md` with full technical reference for all 8 source types (pipe, tcp, airplay, librespot, alsa, meta, file, tcp client), JSON-RPC API, source type schema, and Android/Tidal streaming guide
- **Operations guide** — `docs/USAGE.md` with architecture, services, MPD control, mDNS setup, deployment, CI/CD, and configuration reference
- **Hardware & network guide** — `docs/HARDWARE.md` with server/client requirements, Raspberry Pi models, audio output options, network bandwidth calculations, WiFi vs Ethernet, recommended setups (budget/mid/enthusiast), and known limitations
- **Italian translations** — Bilingual repo: `README.it.md`, `docs/USAGE.it.md`, `docs/SOURCES.it.md`, `docs/HARDWARE.it.md` with language switchers on all docs
- **Essential README** — Simple appliance manual for non-technical users (~100 lines); technical content in `docs/`
- **CI/CD pipelines** — Build, validate, and deploy workflows on self-hosted runners
- **Issue templates** — Bug report and feature request templates for GitHub

### Fixed
- **Server buffer configuration** — Increased buffer from 1000ms to 2400ms and chunk_ms from 20ms to 40ms to compensate for clock drift and network jitter on WiFi connections; see [rpi-snapclient-usb#9](https://github.com/lollonet/rpi-snapclient-usb/issues/9)
- **Deploy workflow** — Target only app services (`snapmulti`, `mpd`), pull pre-built images from ghcr.io, proper error handling with `set -euo pipefail`
- **Docker image tags** — Lowercase image names to comply with Docker naming rules
- **Dockerfile config paths** — Fixed `COPY` paths after config directory reorganization
- **Validation workflow** — Proper error output instead of suppressing to `/dev/null`
- **Documentation alignment** — README and config examples match actual implementation
