# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- **Internal audio config** — `internal-audio.conf` for Pi headphone jack / HDMI fallback
- **bcm2835 detection** — `detect_hat` now identifies onboard audio as explicit fallback

### Fixed
- **IMAGE_TAG not persisted** — `setup.sh` now writes `IMAGE_TAG` and `ENABLE_READONLY` to `.env` (previously lost after reboot)
- **I2C false positive** — keep onboard audio as fallback when I2C scan finds ambiguous chips
- **discover-server.sh** — writes discovered IPv4 to `.env` instead of clearing `SNAPSERVER_HOST`
- **systemctl not-found** — suppress error from `is-enabled` on missing services
- **gpu_mem=16 headless** — reduced GPU memory for headless clients, localhost buffer tuning
- **HAT_DETECTION_SOURCE subshell** — `detect_hat` now runs in current shell via redirect

### Removed
- **Bloat docs** — deleted docs/00-VISION.md, 06-INFRASTRUCTURE.md, 07-TESTING.md, 08-WBS.md (planning artifacts, not user docs)

## [0.2.27] — 2026-04-03

### Added
- **SECURITY.md** — vulnerability disclosure policy
- **CONTRIBUTING.md** — contributor guidelines
- **Dependabot** — Docker + GitHub Actions weekly updates
- **Gitleaks** — secrets detection on push/PR

### Changed
- **Python 3.14** — audio-visualizer and fb-display bumped from 3.13-slim to 3.14-slim
- **SHA-pinned all GitHub Actions** — supply chain security
- **Native arm64 CI builds** — Mac runner replaces QEMU emulation
- **GitHub Actions updated** — setup-qemu 4.0, login 4.1, metadata 6.0, build-push 7.0, setup-buildx 4.0

### Fixed
- **Clear stale SNAPSERVER_HOST** — discover-server.sh removes hardcoded IPs (including 127.0.0.1 from old both-mode) at boot, forcing mDNS autodiscovery

### Removed
- **deploy.yml** — SSH deployment workflow removed (reflash only)

## [0.2.26] — 2026-04-02

### Added
- **Album details on display** ([#116](https://github.com/lollonet/snapclient-pi/pull/116)) — shows year, genre, track number, disc number below album name (`1978 · Reggae · Track 3 · Disc 1`). Only displayed when metadata is available.

## [0.2.25] — 2026-04-02

### Fixed
- **Changelog** — added missing entries for v0.2.20–v0.2.24

## [0.2.24] — 2026-03-31

### Changed
- **Repo renamed** to `snapclient-pi` (was `rpi-snapclient-usb`). GitHub redirects old URLs.
- **Docker images** renamed: `lollonet/snapclient-pi[-*]:latest`

### Fixed
- **Broken relative links** ([#115](https://github.com/lollonet/snapclient-pi/pull/115)) — rename sed corrupted paths in QUICKSTART.md and README.md

## [0.2.23] — 2026-03-31

### Changed
- **Shared Docker install** ([#113](https://github.com/lollonet/snapclient-pi/pull/113)) — setup.sh uses shared `install_docker_apt()` instead of inline 25-line Docker CE installation

## [0.2.22] — 2026-03-30

### Added
- **Periodic snapserver re-discovery** ([#110](https://github.com/lollonet/snapclient-pi/pull/110)) — systemd timer re-discovers snapserver every 5min via mDNS; restarts snapclient only when server IP changes

### Fixed
- **Don't write discovered IP to .env** ([#111](https://github.com/lollonet/snapclient-pi/pull/111)) — preserves autodiscovery; uses volatile `/run/` tracking
- **Both-mode restart rollback** ([#112](https://github.com/lollonet/snapclient-pi/pull/112)) — only update .env after successful restart
- **Shellcheck source directive** — silence SC1090 for system-tune.sh dynamic source

## [0.2.21] — 2026-03-29

### Fixed
- **Source system-tune.sh at top of file** — was sourced after functions that depend on it

## [0.2.20] — 2026-03-29

### Fixed
- **Pin numpy==2.4.3** — 2.1.6 incompatible with Python 3.13

## [0.2.19] — 2026-03-25

### Added
- **Hardware mixer auto-detection** ([#105](https://github.com/lollonet/snapclient-pi/pull/105)) — `setup.sh` auto-configures `MIXER` based on detected audio HAT. Hardware mixer for DACs with volume control (PCM5122, PCM1794A, TAS5756M, DA7212, WM8960), software for S/PDIF and USB. Preserves full 16-bit audio resolution at all volume levels

### Fixed
- **CPU governor and USB autosuspend** ([#104](https://github.com/lollonet/snapclient-pi/pull/104)) — sets CPU governor to `performance` and disables USB autosuspend to prevent audio glitches
- **display.sh safety and permissions** ([#106](https://github.com/lollonet/snapclient-pi/pull/106)) — added `set -euo pipefail` to display.sh; setup.sh now sets execute permission on display.sh after copy

## [0.2.18] — 2026-03-23

### Changed
- **Resource profiles optimized from production measurements** ([#100](https://github.com/lollonet/snapclient-pi/pull/100), [#101](https://github.com/lollonet/snapclient-pi/pull/101)) — re-baselined Docker CPU and memory limits using live measurements; documentation coherence fixes

### Fixed
- **HiFiBerry DAC+ auto-detect misconfiguration** ([#96](https://github.com/lollonet/snapclient-pi/issues/96)) — Changed `hifiberry-dacplus` overlay to `hifiberry-dacplus-std` to force Pi as clock master; the auto-detect overlay incorrectly identifies Standard boards as Pro when EEPROM is absent, causing DAC to expect non-existent oscillator
- **I2C enablement for PCM512x-based HATs** — Added `dtparam=i2c_arm=on` to config.txt for HiFiBerry, InnoMaker, IQaudio, Allo, and Waveshare WM8960 HATs; kernel driver needs I2C access to configure DAC clocks and registers
- **CI deploy tmpfs exhaustion** ([#99](https://github.com/lollonet/snapclient-pi/pull/99)) — reordered deploy steps to prevent overlayroot tmpfs from filling up during image pull + bake
- **Headless mode ignored** ([#102](https://github.com/lollonet/snapclient-pi/pull/102)) — `setup.sh` hardcoded `COMPOSE_PROFILES="framebuffer"` instead of using display detection; headless Pis ran visual containers wasting 128-256M RAM. Now uses `has_display()` from `display.sh`; `audio-visualizer` gated under `framebuffer` profile
- **Display script self-copy crash** ([#103](https://github.com/lollonet/snapclient-pi/pull/103)) — `cp` failed with "are the same file" when `COMMON_DIR == INSTALL_DIR` on firstboot, crashing `setup.sh` under `set -e`

## [0.2.16] — 2026-03-18

### Added
- **Snapclient v0.35.0** ([#95](https://github.com/lollonet/snapclient-pi/pull/95)) — Upgraded from `lollonet/santcasp` fork to upstream `badaix/snapcast` v0.35.0; uses tagged releases for better version control

### Fixed
- **I2C bus scan for HATs without EEPROM** ([#90](https://github.com/lollonet/snapclient-pi/pull/90)) — `detect_hat()` falls back to raw I2C probing before defaulting to USB audio, enabling zero-touch detection for InnoMaker HiFi DAC (PCM5122), Waveshare WM8960, and no-EEPROM Allo/DigiOne variants
- **Enable i2c_arm at runtime before scan** ([#92](https://github.com/lollonet/snapclient-pi/pull/92)) — `dtparam i2c_arm=on` called before I2C scan so `/dev/i2c-1` is available on first boot (before HAT overlay written to `config.txt`)
- **Raise fb-display memory limit in minimal profile** ([#91](https://github.com/lollonet/snapclient-pi/pull/91)) — `FBDISPLAY_MEM_LIMIT` increased from 128M to 192M for Pi 3B+ / Pi Zero 2 W; observed runtime usage is ~120 MiB, leaving only 8M headroom at old limit
- **Redirect apt-get stdout in detect_hat()** ([#93](https://github.com/lollonet/snapclient-pi/pull/93)) — apt-get output redirected to stderr so package messages don't corrupt `AUDIO_HAT` variable
- **C.UTF-8 locale system-wide** ([#94](https://github.com/lollonet/snapclient-pi/pull/94)) — Set `LANG=C.UTF-8` / `LC_ALL=C.UTF-8` to suppress locale warnings during apt operations; removed unused `gnupg` from base packages

### Changed
- **CI resilience** ([#89](https://github.com/lollonet/snapclient-pi/pull/89)) — Trivy scans use `continue-on-error: true` so network failures don't block deploys

## [0.2.13] — 2026-03-17

### CI/CD
- **Fix HOST secret in reusable workflow deploys** ([#fix](https://github.com/lollonet/snapclient-pi)) — GitHub Actions does not expose environment-scoped secrets to `workflow_call` reusable workflows (only `workflow_dispatch`). Changed to explicit `HOST_SNAPVIDEO` / `HOST_SNAPDIGI` repo-level secrets passed via the `secrets:` block. Environment declarations retained for protection rules and deployment tracking.

## [0.2.12] — 2026-03-17

### CI/CD
- Tagging to trigger v0.2.11 with correct HOST secrets

## [0.2.11] — 2026-03-17

### CI/CD
- **Trivy scans: continue-on-error** ([#89](https://github.com/lollonet/snapclient-pi/pull/89)) — added `continue-on-error: true` to all three Trivy steps; network failures downloading the Trivy binary must not block deploys (Trivy is reporting-only)

## [0.2.10] — 2026-03-16

### Fixed
- **Silent failure in LAN IP detection** ([#88](https://github.com/lollonet/snapclient-pi/pull/88)) — `_get_lan_ip()` in `fb_display.py`: `except Exception:` narrowed to `except OSError as e:` with warning log

### Security
- **Non-root Docker images** ([#86](https://github.com/lollonet/snapclient-pi/pull/86)) — added `USER 1000` and `--chown=1000:1000` to `snapclient`, `audio-visualizer`, and `fb-display` Dockerfiles; pinned `uv:latest` → `uv:0.6.3`

### CI/CD
- **GitHub Environments for deploy** ([#85](https://github.com/lollonet/snapclient-pi/pull/85)) — `HOST_SNAPVIDEO`/`HOST_SNAPDIGI` secrets moved to environment-scoped `snapvideo`/`snapdigi` environments; `deploy.yml` declares `environment:` for automatic secret resolution; concurrency group prevents concurrent deploys to same device
- **Trivy container scanning** ([#87](https://github.com/lollonet/snapclient-pi/pull/87)) — added vulnerability scanning to all build jobs (HIGH/CRITICAL, exit-code 0)

## [0.2.9] — 2026-03-16

### Fixed
- **fb-display: skip redraw on unchanged server_info** ([#83](https://github.com/lollonet/snapclient-pi/pull/83)) — avoid unnecessary framebuffer writes when `server_info` content is identical to previous
- **setup.sh: read APP_VERSION from VERSION file** ([#82](https://github.com/lollonet/snapclient-pi/pull/82)) — `APP_VERSION` now read from the `VERSION` file baked by `prepare-sd.sh` rather than hard-coded

### Maintenance
- **GitHub Actions: Node.js 24 compatible versions** ([#81](https://github.com/lollonet/snapclient-pi/pull/81)) — updated `actions/checkout`, `docker/setup-buildx-action`, etc. to versions that support Node.js 24 runtime

## [0.2.8] — 2026-03-10

### Added
- **Automated CI deploy with overlayroot bake** ([#80](https://github.com/lollonet/snapclient-pi/pull/80)) — `deploy.yml` reusable workflow: copies files, pulls images, bakes deployment to SD card lower layer (`/media/root-ro`) so updates survive Pi reboots; `docker-build.yml` calls it for both `snapvideo` and `snapdigi` after all build jobs pass

## [0.2.7] - 2026-03-10

### Fixed
- **Snapclient Built from santcasp Fork** ([#79](https://github.com/lollonet/snapclient-pi/pull/79)) — Dockerfile now clones from `lollonet/santcasp` (develop branch) matching the snapMULTI server build. Docker cache busting via `SANTCASP_SHA` ARG was previously inert (ARG declared but not referenced in any `RUN` step); fixed by echoing the SHA in the `git clone` step. Added `grep -q` assertion after `sed` to fail fast if the version pattern isn't found.

## [0.2.6] - 2026-03-10

### Added
- **15 Audio HATs Supported** ([#78](https://github.com/lollonet/snapclient-pi/pull/78)) — Added HiFiBerry AMP2, HiFiBerry DAC+ ADC Pro, Innomaker DAC PRO (ES9038Q2M), and Waveshare WM8960 with full EEPROM and ALSA auto-detection. Interactive setup menu extended to all 15 boards. (Note: Innomaker HIFI DAC HAT PCM5122 was already supported via `allo-boss` config.)

## [0.2.5] - 2026-03-10

### Fixed
- **Both Versions in Status Line** ([#77](https://github.com/lollonet/snapclient-pi/pull/77)) — Status bar now shows client *and* server versions simultaneously (e.g. `192.168.x.x → snapvideo • v0.2.5 / srv 0.3.7`). Previously only one was shown (fallback logic). Displays whichever subset is available.

### Documentation
- **Docs Suite Updated to v0.2.4** — Corrected field names (`elapsed`/`playing`/`artwork` replacing stale names), added `server_info` message type, fixed spectrum wire format (semicolon-delimited, not JSON), added new env vars, updated test counts (109 pytest + 22 shell), updated WBS with v0.2.2–v0.2.4 features.

## [0.2.4] - 2026-03-09

### Added
- **Server version in status bar** ([#76](https://github.com/lollonet/snapclient-pi/pull/76)) — Bottom bar now shows the snapMULTI server version received via WebSocket `server_info` message (e.g. `192.168.x.x  →  snapvideo  v0.3.7`). Falls back to `APP_VERSION` env var when no WS data is available yet
- **App version in status bar** ([#75](https://github.com/lollonet/snapclient-pi/pull/75)) — `APP_VERSION` env var (set by `setup.sh` from git tag) shown in bottom bar as fallback when server version is not yet available

## [0.2.3] - 2026-03-07

### Added
- **Network-Aware ALSA Tuning** ([#74](https://github.com/lollonet/snapclient-pi/pull/74)) - Auto-detect WiFi vs Ethernet and set appropriate ALSA buffer defaults (WiFi: 250ms/8 frags, Ethernet: 150ms/4 frags); overridable via `snapclient.conf`
- **WiFi Power Save Disabled** ([#74](https://github.com/lollonet/snapclient-pi/pull/74)) - Automatically disable WiFi power management during setup to prevent audio dropouts; persistent via NetworkManager config
- **CONNECTION_TYPE Config** ([#74](https://github.com/lollonet/snapclient-pi/pull/74)) - New `.env` variable for network type; auto-detected or manually overridable

### Changed
- **Snapclient URL Format** ([#74](https://github.com/lollonet/snapclient-pi/pull/74)) - Migrate entrypoint.sh from deprecated `--host`/`--port` flags to `tcp://host:port` URL format

### Fixed
- **Setup Fails on Missing discover-server.sh** ([#71](https://github.com/lollonet/snapclient-pi/pull/71)) - Guard file install with existence check; use systemd `ExecStartPre=-` prefix so containers start even without the discovery script
- **Double Docker Image Pull** ([#72](https://github.com/lollonet/snapclient-pi/pull/72)) - Move read-only/fuse-overlayfs config before `docker compose pull` so images are only downloaded once
- **SSH Host Keys Lost on Read-Only Reboot** ([#72](https://github.com/lollonet/snapclient-pi/pull/72)) - Persist SSH host keys before enabling overlayfs via systemd restore service; prevents "REMOTE HOST IDENTIFICATION HAS CHANGED" on every reboot
- **avahi-browse Hangs During Setup** ([#72](https://github.com/lollonet/snapclient-pi/pull/72)) - Added 10s timeout to mDNS discovery to prevent setup from hanging if avahi-daemon is slow to start
- **SNAPSERVER_HOST Cleared on Re-run** ([#72](https://github.com/lollonet/snapclient-pi/pull/72)) - Don't overwrite existing value with empty string when mDNS discovery fails during setup re-run
- **Missing File Guards** ([#72](https://github.com/lollonet/snapclient-pi/pull/72)) - Guard `ro-mode.sh` and `daemon.json` installs with existence checks (same pattern as discover-server.sh)

## [0.2.2] - 2026-03-07

### Added
- **LAN IP and Snapserver in Display** ([#68](https://github.com/lollonet/snapclient-pi/pull/68)) - Status line in bottom bar shows `192.168.63.5 → snapvideo.local` for easy identification of client and server
- **mDNS Auto-Discovery for Server Failover** ([#70](https://github.com/lollonet/snapclient-pi/pull/70)) - fb-display discovers alternative snapservers via `_snapcast._tcp` mDNS after 3 failed reconnects; switches server and updates status line automatically

### Fixed
- **Missing avahi-utils** ([#69](https://github.com/lollonet/snapclient-pi/pull/69)) - Added `avahi-utils` to setup.sh `BASE_PACKAGES` so `avahi-browse` is available for mDNS discovery

## [0.2.1] - 2026-03-05

### Added
- **Big-Endian Framebuffer Support** ([#66](https://github.com/lollonet/snapclient-pi/pull/66)) - XRGB pixel format for big-endian platforms (PowerPC); spectrum analyzer uses explicit little-endian dtype for cross-platform loopback compatibility
- **mDNS Server Discovery on Boot** ([#65](https://github.com/lollonet/snapclient-pi/pull/65)) - `discover-server.sh` resolves snapserver IP via Avahi on every boot, replacing stale `.env` entries

### Changed
- **Unified SNAPSERVER_HOST** ([#64](https://github.com/lollonet/snapclient-pi/pull/64)) - `METADATA_HOST` is now derived from `SNAPSERVER_HOST` in docker-compose; removed as separate user-facing config

### Fixed
- **Progress Bar Position** ([#66](https://github.com/lollonet/snapclient-pi/pull/66)) - Moved progress bar above the bottom bar for better visual layout

## [0.2.0] - 2026-03-04

### Added
- **Post-Install Verification Checklist** ([#37](https://github.com/lollonet/snapclient-pi/issues/37), [#63](https://github.com/lollonet/snapclient-pi/pull/63)) - Step-by-step checklist with commands and expected outputs for Docker, audio, display, spectrum, and read-only FS
- **Troubleshooting Section** ([#38](https://github.com/lollonet/snapclient-pi/issues/38), [#63](https://github.com/lollonet/snapclient-pi/pull/63)) - Problem/cause/fix tables for audio, display, network, Docker, and read-only filesystem issues
- **Hardware Compatibility Matrix** ([#39](https://github.com/lollonet/snapclient-pi/issues/39), [#63](https://github.com/lollonet/snapclient-pi/pull/63)) - Tested/untested status for Pi models (3B+ through 5) and display types
- **Broadcast Dedup** ([#60](https://github.com/lollonet/snapclient-pi/pull/60)) - WebSocket broadcast skips identical consecutive frames during silence (~27 fewer sends/sec per client)

### Changed
- **float32 Hot Path** ([#60](https://github.com/lollonet/snapclient-pi/pull/60)) - Smoothing coefficients and cumsum buffer use float32 to avoid implicit float64 promotion in visualizer
- **CI Review Workflow** - Allow bot-triggered reviews (`allowed_bots`), removed `use_sticky_comment` to preserve review history, reduced `fetch-depth` to 1

### Fixed
- **RGB565 LUT Regression** ([#62](https://github.com/lollonet/snapclient-pi/pull/62)) - Reverted lookup table approach; direct `astype(uint16)` + bitwise is 35-75% faster on ARM Cortex-A72
- **Exception Handlers** ([#57](https://github.com/lollonet/snapclient-pi/pull/57), [#58](https://github.com/lollonet/snapclient-pi/pull/58)) - Narrowed broad `except Exception` handlers, replaced `socket.error`/`socket.timeout` with `OSError`/`TimeoutError`, added SSRF/injection tests
- **Shell Script Hardening** ([#57](https://github.com/lollonet/snapclient-pi/pull/57)) - Added input validation and safe quoting across setup scripts

### Removed
- **Dead Metadata Service** ([#59](https://github.com/lollonet/snapclient-pi/issues/59), [#61](https://github.com/lollonet/snapclient-pi/pull/61)) - Removed `common/docker/metadata-service/` (1,831 lines), tests, CI steps, and Docker build job. Metadata is served by the snapMULTI server

## [0.1.9] - 2026-03-02

### Fixed
- **800x600 Install Resolution Persists** ([#55](https://github.com/lollonet/snapclient-pi/pull/55)) - `setup.sh` now warns that a reboot is required after removing the temporary `video=HDMI-A-1:800x600` parameter from cmdline.txt. Also uses a robust sed pattern to handle any resolution variant, and verifies the removal succeeded

## [0.1.8] - 2026-03-01

### Added
- **Source Label** ([#53](https://github.com/lollonet/snapclient-pi/pull/53)) - Info panel shows source name (MPD, Spotify, AirPlay, etc.), title, artist, album, and format badge
- **Hardware Mixer Volume** ([#52](https://github.com/lollonet/snapclient-pi/pull/52)) - Spectrum analyzer uses hardware mixer level for volume-independent display instead of software gain
- **Unit Test Suite** ([#51](https://github.com/lollonet/snapclient-pi/pull/51)) - 29 pytest tests covering visualizer, fb-display, and metadata-service logic (socket handling, caching, codec detection, audio format parsing, circuit breakers)
- **SSOT Documentation** - Single source of truth for config (`.env.example`), HAT list (`README.md`), architecture (`CLAUDE.md`). Other files link instead of duplicating

### Changed
- **Remove Browser Display Mode** - Removed X11/Chromium browser mode from setup.sh (was broken after nginx removal). Framebuffer is now the only display mode. Cleaned up all browser references from docs and configs
- **Read-Only Containers** ([#49](https://github.com/lollonet/snapclient-pi/pull/49)) - All 3 client containers now run with `read_only: true` + tmpfs for writable paths
- **Non-Root Containers** ([#49](https://github.com/lollonet/snapclient-pi/pull/49)) - All 3 containers run as uid 1000 with `group_add` for device access (audio, video), `cap_drop: ALL`

### Fixed
- **Socket Leak** ([#54](https://github.com/lollonet/snapclient-pi/pull/54)) - `_create_socket_connection` now closes socket on connect failure instead of leaking file descriptors
- **FD Leak** ([#54](https://github.com/lollonet/snapclient-pi/pull/54)) - `open_framebuffer` closes fd if mmap fails instead of leaking
- **Cache Unbounded Growth** ([#54](https://github.com/lollonet/snapclient-pi/pull/54)) - Artwork, artist image, and failed download caches now bounded (500/200/200) with oldest-half eviction. Failed downloads use TTL (5 min) for automatic retry
- **Circuit Breakers** ([#54](https://github.com/lollonet/snapclient-pi/pull/54)) - Main loop (30 errors) and render loop (50 errors) exit instead of spinning forever on persistent failures
- **Thread Safety** ([#54](https://github.com/lollonet/snapclient-pi/pull/54)) - `resize_bands` race condition fixed by moving guard inside lock
- **Font Cache Bounded** ([#54](https://github.com/lollonet/snapclient-pi/pull/54)) - Font cache limited to 200 entries with FIFO eviction
- **MPD Response Loop** ([#53](https://github.com/lollonet/snapclient-pi/pull/53)) - `_read_mpd_response` breaks on empty recv instead of looping forever on closed connection
- **Spectrum Raw dBFS** ([#47](https://github.com/lollonet/snapclient-pi/pull/47), [#50](https://github.com/lollonet/snapclient-pi/pull/50)) - Removed total-power normalization and auto-gain from spectrum analyzer. Bars now show raw dBFS with fixed 60 dB display range
- **Progress Display Bouncing** ([#49](https://github.com/lollonet/snapclient-pi/pull/49)) - `setup.sh` defers to parent's progress display via `PROGRESS_MANAGED=1`. Replaced Unicode chars with ASCII-safe equivalents for PSF fonts
- **Documentation Coherence** - Updated all docs to reflect removal of client-side metadata-service and nginx containers
- **METADATA_HTTP_PORT Consistency** ([#45](https://github.com/lollonet/snapclient-pi/pull/45)) - Aligned all port defaults to 8083 across docker-compose.yml, fb_display.py, and setup.sh
- **CI Workflow Context** - Updated claude-code-review.yml: Python 3.11→3.13, removed stale metadata-service reference

## [0.1.7] - 2026-02-19

### Changed
- **Docker Hub Registry** ([#41](https://github.com/lollonet/snapclient-pi/pull/41)) - Moved all container images from GHCR to Docker Hub (`lollonet/snapclient-pi-*`) for faster pull speeds. CI workflow updated to use Docker Hub credentials
- **Simplified Clock** ([#40](https://github.com/lollonet/snapclient-pi/pull/40)) - Replaced retro-styled decorated clock (double borders, text shadow, corner dots) with a small muted plain-text clock at half the font size

### Fixed
- **Display Flicker** ([#40](https://github.com/lollonet/snapclient-pi/pull/40)) - Added dirty flag to clock and progress bar caches so framebuffer writes only happen when content actually changes (~1x/sec instead of every frame)
- **Setup Hard-Fail** ([#42](https://github.com/lollonet/snapclient-pi/pull/42)) - Critical setup errors (Docker pull failure, missing Chromium, missing boot config) now exit with error instead of printing a warning and reporting "Setup Complete!"
- **grep -c Bug** ([#43](https://github.com/lollonet/snapclient-pi/pull/43)) - Fixed `setup.sh` progress renderer outputting `"0\n0"` when input was empty due to `grep -c` returning non-zero exit on no match
- **Artwork Port Default** ([#43](https://github.com/lollonet/snapclient-pi/pull/43)) - Fixed `METADATA_HTTP_PORT` default from 8083 to 8080 to match nginx cover-webserver port
- **Missing fb-display Env Vars** ([#43](https://github.com/lollonet/snapclient-pi/pull/43)) - Added `METADATA_HOST`, `METADATA_HTTP_PORT`, and `CLIENT_ID` to docker-compose.yml for fb-display service

## [0.1.6] - 2026-02-19

### Changed
- **Docker Hub Registry** ([#41](https://github.com/lollonet/snapclient-pi/pull/41)) - Initial registry switch from GHCR to Docker Hub

### Documentation
- **DISPLAY_RESOLUTION** - Fixed README example to show empty value (auto-detect) instead of hardcoded `1920x1080`
- **mDNS Limitation** - Documented that metadata-service mDNS discovery runs once at startup with no failover

## [0.1.5] - 2026-02-18

### Added
- **MIT License** - Added MIT license to project

### Changed
- **Python 3.13** - Upgraded all Python Docker images from 3.11-slim to 3.13-slim (metadata-service, audio-visualizer, fb-display)
- **CI Parallelization** - All 4 Docker image builds now run in parallel (removed sequential dependencies). Deployed 4 self-hosted runners on raspy for faster builds (~3 min vs ~12 min)
- **Documentation Updates** - Synced README, CLAUDE.md, and CHANGELOG with current project state
- **Code Architecture** ([#36](https://github.com/lollonet/snapclient-pi/pull/36)) - Consolidated code duplication across three areas:
  - Removed dead font wrapper functions (simplified API)
  - Extracted generic `websocket_client_loop()` utility (85% duplication eliminated)
  - Consolidated MPD greeting pattern into reusable helper (3 duplicate patterns eliminated)

### Fixed
- **Error Handling and Logging** ([#35](https://github.com/lollonet/snapclient-pi/pull/35)) - Improved error visibility:
  - Log MPD binary size parsing failures instead of silently passing
  - Separate network/IO errors from unexpected errors in MPD operations
  - Log malformed JSON from Snapserver with sample data for debugging
  - Escalate framebuffer write failures from warning to error level
- **Python 3.9 Compatibility** - Replace Python 3.10+ union type hints (`callable | None`) with `Optional[Callable]` for older Python versions
- **Documentation Default Values** - Corrected default values in documentation to match setup.sh behavior:
  - `ENABLE_READONLY=true` (was incorrectly documented as false in .env.example)
  - `DISPLAY_MODE=framebuffer` (was incorrectly documented as browser in .env.example)
  - `BAND_MODE=third-octave` default (CLAUDE.md incorrectly stated half-octave as default)
- **Documentation Accuracy** - Fixed README and CLAUDE.md inconsistencies found during 10-pass review:
  - Standardized Docker image naming across all docs
  - Added Docker Compose v2+ requirement
  - Clarified read-only filesystem is enabled by default

## [0.1.4] - 2026-02-11

### Added
- **Song Progress Bar** - Display elapsed/duration time with visual progress bar for file playback. Uses Snapserver MPRIS properties (position, duration) with local clock for smooth updates

### Changed
- **Touch Controls Reverted** - Touch screen controls removed pending UX redesign. Will return in a future release

### Fixed
- **Snapserver Artwork SSRF** - Allow artwork downloads from Snapserver host (was blocked by private IP protection)
- **Control Command Logging** - Improved logging for debugging control commands

## [0.1.3] - 2026-02-10

### Added
- **Touch Screen Controls** ([#34](https://github.com/lollonet/snapclient-pi/pull/34)) - Tap to toggle play/pause, swipe up/down for volume control. Gracefully degrades on non-touch displays

### Fixed
- **Spectrum DC offset** - Remove DC component before FFT to prevent false 20 Hz activity during speech/radio content
- **Metadata thread safety** - Add lock for socket operations to prevent JSON-RPC stream corruption when control commands arrive during polling
- **Touch volume sensitivity** - Scale swipe distance by screen height and cap at ±10 per gesture for more predictable control
- **evdev build dependencies** - Add gcc, libc-dev, linux-libc-dev to fb-display Dockerfile for evdev compilation
- **Metadata stale connection** ([#31](https://github.com/lollonet/snapclient-pi/pull/31)) - Add 10s socket timeout and 30s staleness threshold to detect half-open TCP connections to snapserver
- **Spectrum analyzer accuracy** ([#32](https://github.com/lollonet/snapclient-pi/pull/32)) - Increase FFT size to 8192 for better low-frequency resolution (5.4 Hz/bin), tune smoothing for smoother visuals

## [0.1.1] - 2026-02-07

### Added
- **SnapForge Branding** ([#30](https://github.com/lollonet/snapclient-pi/pull/30)) - Brand text logo displayed next to icon in bottom bar
- **Read-Only Root Filesystem** ([#25](https://github.com/lollonet/snapclient-pi/pull/25)) - SD card protection using raspi-config overlayfs, enabled by default. Includes Docker fuse-overlayfs storage driver and `ro-mode` helper script
- **WebSocket Metadata Push** - Metadata service pushes updates via WebSocket instead of HTTP polling, reducing latency

### Changed
- **Bottom Bar Redesign** ([#27](https://github.com/lollonet/snapclient-pi/pull/27)) - Logo (left), date+time (center), enlarged volume knob (right). Clock shows `Thu 05 Feb · HH:MM:SS` format
- **Read-only filesystem enabled by default** - Use `--no-readonly` flag to disable

### Fixed
- **ARM64 ctypes** ([#30](https://github.com/lollonet/snapclient-pi/pull/30)) - Add argtypes/restype for snd_pcm_readi to prevent 64-bit return value truncation on RPi 4/5
- **Spectrum range** ([#27](https://github.com/lollonet/snapclient-pi/pull/27)) - Extended from 20Hz–10kHz to full 20Hz–20kHz (21 bands)
- **Persistent TCP** ([#26](https://github.com/lollonet/snapclient-pi/pull/26)) - Metadata service uses single connection to snapserver instead of reconnecting each poll
- **Dead code cleanup** ([#29](https://github.com/lollonet/snapclient-pi/pull/29)) - Remove stale comments, unused variables, duplicate changelog headings
- **RO-mode status detection** - Fix overlayroot mount detection in status check
- **Visualizer healthcheck** - Use process check instead of TCP connect to avoid WebSocket error spam

### Security
- **CSP Header** ([#30](https://github.com/lollonet/snapclient-pi/pull/30)) - Add Content-Security-Policy meta tag to web UI for defense-in-depth

### Documentation
- **CLAUDE.md rewrite** ([#28](https://github.com/lollonet/snapclient-pi/pull/28)) - Architecture map and operational rules

## [0.1.0] - 2026-02-05

Initial release with core feature set.

### Features

- **11 Audio HATs Supported** - HiFiBerry (DAC+, Digi+, DAC2 HD), IQaudio (DAC+, DigiAMP+, Codec Zero), Allo (Boss, DigiOne), JustBoom (DAC, Digi), USB Audio
- **HAT Auto-Detection** - Reads EEPROM at `/proc/device-tree/hat/product`, falls back to ALSA card names, then USB
- **mDNS Autodiscovery** - Snapserver found via `_snapcast._tcp` mDNS, no IP configuration needed
- **Zero-Touch Install** - Flash SD, copy files with `prepare-sd.sh`, boot Pi, wait 5 minutes
- **Install Progress Display** - Visual progress on HDMI during install (800x600)
- **Cover Display** - Full-screen album art with track metadata on framebuffer or browser
- **Artwork Sources** - MPD embedded → iTunes (validated) → MusicBrainz/Cover Art Archive → Radio-Browser
- **Real-Time Spectrum Analyzer** - dBFS FFT with half-octave (21) or third-octave (31) bands
- **Auto-Gain Normalization** - Spectrum reflects shape regardless of volume, with volume indicator
- **Standby Screen** - Retro VU meter artwork with breathing animation when idle
- **Adaptive FPS** - 20 FPS (spectrum), 5 FPS (playing), 1 FPS (idle) to save CPU
- **Digital Clock** - Nerdy retro-style clock on install progress and framebuffer display
- **Container Healthchecks** - All services with `condition: service_healthy` dependencies
- **Resource Limits** - Auto-detected CPU/memory limits based on Pi RAM (2GB/4GB/8GB profiles)

### Security

- **Input Validation** - Shell metacharacter rejection, path traversal prevention
- **SSRF Protection** - URL scheme validation, DNS resolution, private IP blocking (IPv4 + IPv6)
- **Granular Capabilities** - Specific caps (SYS_NICE, IPC_LOCK) instead of privileged mode
- **Hardened tmpfs** - All mounts use `noexec,nosuid,nodev` flags
- **MPD Protocol Hardening** - Control char rejection, socket timeouts, binary size limits
- **Thread Safety** - Locks for shared state, bounds validation, type-safe operations

### Technical

- **ALSA Loopback** - `snd-aloop` decouples DAC from spectrum analyzer, prevents XRUN
- **Buffer Tuning** - 150ms buffer, 4 fragments for underrun prevention
- **Docker-based** - Pre-built ARM64 images on Docker Hub
- **Systemd Services** - Auto-start on boot
- **CI/CD** - Shellcheck, Hadolint, HAT config tests, Docker builds on tags
