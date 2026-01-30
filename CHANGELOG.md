# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- **Initial Docker setup** — Snapcast server and MPD running in Alpine Linux containers with CI/CD pipelines — Jan 26
- **MPD configuration** — Music Player Daemon with FIFO output to Snapcast — Jan 26
- **mDNS autodiscovery** ([#1](https://github.com/lollonet/snapMULTI/pull/1)) — Automatic client discovery via Avahi/Bonjour using host D-Bus socket — Jan 26–27
- **Multi-source audio** — Three audio sources: MPD (local library), TCP input (port 4953), and AirPlay (via shairport-sync) — Jan 27
- **Issue templates** — Bug report and feature request templates for GitHub — Jan 28
- **Spotify Connect** ([#2](https://github.com/lollonet/snapMULTI/issues/2)) — Fourth audio source via librespot (Spotify Premium required, 320 kbps) — Jan 29
- **Audio sources reference** — `docs/SOURCES.md` with full technical reference for all 8 source types (pipe, tcp, airplay, librespot, alsa, meta, file, tcp client), JSON-RPC API, source type schema for management apps, and Android/Tidal streaming guide — Jan 30
- **Additional source examples** — ALSA capture, meta stream, file playback, and TCP client added as commented-out examples in `snapserver.conf` — Jan 30

- **Operations guide** — `docs/USAGE.md` with architecture, services, MPD control, mDNS setup, deployment, CI/CD, and configuration reference — Jan 30
- **Italian translations** — Bilingual repo: `README.it.md`, `docs/USAGE.it.md`, `docs/SOURCES.it.md` with language switchers on all docs — Jan 30
- **Hardware & network guide** — `docs/HARDWARE.md` (EN + IT) with server/client requirements, Raspberry Pi models, audio output options, network bandwidth calculations, WiFi vs Ethernet, recommended setups (budget/mid/enthusiast), and known limitations — Jan 30

### Changed
- **Essential README** — Slimmed README from 435 to ~100 lines; technical content moved to `docs/USAGE.md`; README now reads as a simple appliance manual for non-technical users — Jan 30
- **Project rename** — Renamed from `snapcast` to `snapMULTI` across all files, configs, Docker images, and GitHub repo — Jan 28
- **Configuration reorganization** — Moved config files into `config/` directory — Jan 27
- **Host networking** — Switched to `network_mode: host` for mDNS broadcast support — Jan 26
- **Self-hosted CI runner** — All workflows now run on custom `snapcast-runner` instead of GitHub-hosted runners — Jan 28
- **Container registry** ([#3](https://github.com/lollonet/snapMULTI/issues/3)) — Multi-arch images (amd64 + arm64) built in CI and pushed to ghcr.io; deploy pulls pre-built images instead of building on server — Jan 28

### Fixed
- **Deploy workflow** — Target only app services (`snapmulti`, `mpd`), pull pre-built images from ghcr.io, proper error handling with `set -euo pipefail` — Jan 28
- **Docker image tags** — Lowercase image names to comply with Docker naming rules — Jan 28
- **Dockerfile config paths** — Fixed `COPY` paths after config directory reorganization — Jan 28
- **Validation workflow** — Proper error output instead of suppressing to `/dev/null` — Jan 28
- **Documentation alignment** — README and config examples match actual implementation — Jan 27–28
