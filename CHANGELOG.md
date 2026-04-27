# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed
- **Consolidated apt operations during firstboot** — Docker apt repo now added before `install-deps.sh`'s `apt-get update`, so a single update covers Debian + Docker sources. `fuse-overlayfs` moved into `install-deps.sh` (gated on `ENABLE_READONLY=true`). Result: 2 `apt-get update` → 1, 3 `apt-get install` → 2. Saves ~15s on Pi 4 firstboot. Failure isolation preserved (Debian and Docker installs remain separate transactions)
- **MPD database backup gated on network source** — `prepare-sd.sh` and `firstboot.sh` now restore `mpd/data/mpd.db` only when `MUSIC_SOURCE=nfs` or `smb`. For local USB/disk sources the db is skipped: scan is fast on local storage, and the db's path pointers may not match the new host's library (see [#278](https://github.com/lollonet/snapMULTI/issues/278))

### Fixed
- **Snapclient failover never triggered when its server died** — `discover-server.sh --watch` updated `SNAPSERVER_HOST=` in `.env` then ran `docker compose restart`, but `restart` does not re-read `.env`, so snapclient came back up bound to the old (dead) IP and stayed there. Switched to `docker compose up -d` (re-evaluates compose+env, recreates only when effective config differs). Combined with three companion changes to give real multi-server failover:
  - Health-check the current `SNAPSERVER_HOST` via TCP probe on port 1704 before scanning mDNS — no flapping when the current server is alive but mDNS happens to return another one first
  - When the current is unreachable, enumerate *all* mDNS results and prefer one different from the current — avoids getting stuck on the dead server's stale Avahi cache entry (1-3 min TTL)
  - Tightened `snapclient-discover.timer` from 5 min to 60 s — failover within ~1 min instead of up to 7 min worst-case
  - Added `[discover]` log prefix and mDNS result list to `journalctl -u snapclient-discover.service` for diagnosis
  - Reconcile drift between container env and `.env`: if `docker inspect snapclient` shows a different `SNAPSERVER_HOST` than `.env` (legacy from the pre-fix `restart` bug, manual `.env` edits, or out-of-band changes), recreate via `up -d` before the TCP-probe shortcut. Without this, a device stuck after the legacy bug stayed bound to the old server forever because the probe trusts `.env` and reported "alive, no scan"
  - Reconcile container runtime state: also `up -d` when `docker inspect`'s `State.Running == false` — covers the case where a previous `up -d` recreated the container with the right config but failed to start (transient docker glitch, e.g. on Pi 3 with `fuse-overlayfs`). Without this, the container sits in `Created` state forever because subsequent cycles see no env drift and exit early
- **`device-smoke.sh` autodetect misclassified client-only as both** — `detect_dir` fell back to `${SCRIPT_DIR}/..` when `/opt/snapmulti` was missing. On a client-only install the script lives at `/opt/snapclient/scripts/`, so the parent (`/opt/snapclient`) matched as a "server" because it had `docker-compose.yml + .env`. Result: autodetect returned `both`, smoke check emitted false errors about missing server containers. Now `detect_dir` validates the candidate compose actually declares the role's service (`snapserver:` or `snapclient:`)
- **Snapclient hardware mixer "Digital" not found on headless HiFiBerry** — snapcast 0.35.0's `alsa_player.cpp` parses the soundcard name to derive the mixer card. With `hw:NAME,0` it splits on `:` and ends up with `mixer_device_ = "hw"` (broken), so `snd_mixer_attach("hw")` finds no controls and snapclient crashes with "Failed to find mixer: Digital". Switched headless `SOUNDCARD` to the equivalent `hw:CARD=NAME,DEV=0` form, which contains the literal `CARD=` substring snapcast needs. Verified on moniaserver (Pi 4, HiFiBerry DAC+ Standard, headless): hardware mixer attaches, control "Digital" found, snapclient stable
- **MPD verify timeout still too tight on Pi 4 2GB** — bumped `verify_services` floor from 120s to 180s. Observed on moniaserver `--both` install: MPD needed 130-150s for listener bind during firstboot (cold caches + image pull I/O contention). Network mounts (NFS/SMB) honor extended `MPD_START_PERIOD` as before; floor only affects local mounts where `MPD_START_PERIOD=30s` default
- **MPD verify timeout too tight during firstboot** — `deploy.sh verify_services` previously gave up after 60s when `MPD_START_PERIOD=30s` (local mounts), but Pi 4 2GB during firstboot needs 90-120s for MPD's listener bind due to cold caches and post-pull I/O contention. Floor verify timeout at 120s, decoupled from MPD's healthcheck `start_period` (which is for Docker, not deploy). Network mounts (NFS/SMB) still get the extended 300s+ window
- **I2C HAT detection false positive on bare Pi 4/5** ([#276](https://github.com/lollonet/snapMULTI/pull/276)) — scan restricted to bus 1 (GPIO header); HDMI internal buses (20/21 on Pi 4, 11/12 on Pi 5) had devices at PCM5122 addresses causing wrong HiFiBerry detection, ALSA crash, and install failure

## [0.6.3] — 2026-04-24

### Fixed
- **Docker images lost after reboot on readonly installs** ([#271](https://github.com/lollonet/snapMULTI/pull/271)) — first boot now pre-configures fuse-overlayfs before image pulls when `ENABLE_READONLY=true`, so images survive the overlayroot transition in the read-only lower layer. Previously Docker re-pulled ~1.5 GB into tmpfs on every reboot
- **boot-tune.sh tmpfs detection** ([#271](https://github.com/lollonet/snapMULTI/pull/271)) — grep `'^/overlay'` never matched Raspberry Pi OS mount at `/media/root-rw`, silently killing all boot tuning (CPU governor, WiFi auto-disable, CAKE QoS, tmpfs resize)
- **Docker driver reverted by deploy/setup** ([#271](https://github.com/lollonet/snapMULTI/pull/271)) — `tune_docker_daemon --live-restore` no longer pops fuse-overlayfs from `daemon.json`
- **Install time corrupted by NTP sync** ([#272](https://github.com/lollonet/snapMULTI/pull/272)) — reset `SECONDS` after NTP jump (Pi without RTC boots at epoch 0)
- **Docker driver reconciliation** ([#268](https://github.com/lollonet/snapMULTI/pull/268)) — boot-time `daemon.json` creation handles missing file; includes log rotation defaults
- **Boot partition kept writable during setup** ([#269](https://github.com/lollonet/snapMULTI/pull/269)) — remount-ro deferred to exit trap
- **Verify lists aligned with deployed files** ([#270](https://github.com/lollonet/snapMULTI/pull/270)) — `prepare-sd.sh` and `firstboot.sh` verify/copy lists include all deployed files
- **TUI log area too tall** ([#274](https://github.com/lollonet/snapMULTI/pull/274)) — capped log area to 8 lines; header, progress bar and step checklist now always visible on 800x600 framebuffer
- **Display-detect no longer manages container lifecycle** (`6cbba85`) — systemd owns it
- **Docker driver reconciliation split into separate systemd service** (`620c8fc`) — `Before=docker.service`
- **Pull progress echoed to stdout for install log capture** (`745b04c`)

## [0.6.2] — 2026-04-23

### Removed
- **Watchtower removed completely** — from compose, .env.example, and documentation; reflash is the only supported update path

## [0.6.1] — 2026-04-22

### Added
- **Framebuffer display screenshot in README**

### Fixed
- **Boot partition remount safety** — chain of EXIT trap fixes for set -e compatibility: exit code preserved across cleanup, boot partition always restored to read-only

## [0.6.0] — 2026-04-22

Architecture reduction epic — 9 PRs (#247-#266) collapsing authority fragmentation across server and client install paths.

### Added
- **Real-device acceptance gate** ([#257](https://github.com/lollonet/snapMULTI/pull/257)) — `device-smoke.sh` validates root mount, Docker driver, systemd units, compose health, and recent error logs. Every tagged release requires `--both` green on real Pi hardware
- **Architecture decision record** ([#257](https://github.com/lollonet/snapMULTI/pull/257)) — ADR-005 documents three product decisions: reflash-only updates, systemd lifecycle ownership, robustness-first
- **Behavioral daemon.json test** ([#263](https://github.com/lollonet/snapMULTI/pull/263)) — shell tests wired into CI validate tune_docker_daemon JSON mutation

### Changed
- **Post-install lifecycle unified under systemd** ([#261](https://github.com/lollonet/snapMULTI/pull/261)) — snapmulti-server.service and snapclient.service with Docker readiness checks and both-mode ordering
- **Shared host bootstrap** ([#260](https://github.com/lollonet/snapMULTI/pull/260)) — single install-deps.sh with role-based packages replaces inline installs
- **Shared compose verification** ([#258](https://github.com/lollonet/snapMULTI/pull/258)) — single verify-compose.sh replaces three duplicated health-check implementations
- **Deduplicated readonly helpers** ([#262](https://github.com/lollonet/snapMULTI/pull/262)) — SSH key persistence + ro-mode shared between server and client
- **Audio HAT detection extracted** ([#264](https://github.com/lollonet/snapMULTI/pull/264)) — reusable module for HAT auto-detection

### Removed
- **In-place update path** ([#259](https://github.com/lollonet/snapMULTI/pull/259)) — update.sh decommissioned; reflash is the only supported upgrade method

### Fixed
- **Debian trixie overlayroot boot failure** ([#266](https://github.com/lollonet/snapMULTI/pull/266)) — systemd-remount-fs workaround for fsconfig() overlay reconfigure rejection
- **Overlayroot persistence** — reliable activation via cmdline.txt + overlayroot.local.conf
- **TUI size on framebuffer** (`cc0106e`) — compute from framebuffer dimensions when stty fails

## [0.5.2] — 2026-04-21

### Changed
- **Full-width TUI progress display** ([#246](https://github.com/lollonet/snapMULTI/pull/246)) — full terminal width, dynamic log area, WARN/ERROR visible on HDMI console
- **Serial image pull** ([#246](https://github.com/lollonet/snapMULTI/pull/246)) — sequential pulls replace paired background+foreground (fixes SD card IO contention)
- **Locale setup** ([#246](https://github.com/lollonet/snapMULTI/pull/246)) — lightweight locale-gen for 7 locales replaces 236MB locales-all package

### Fixed
- **Docker storage driver follows filesystem state** ([#245](https://github.com/lollonet/snapMULTI/pull/245)) — overlay2 on writable root, fuse-overlayfs only when overlayroot is actually active (was incorrectly gated on ENABLE_READONLY flag, adding 20-40% IO overhead on writable systems)

## [0.5.1] — 2026-04-19

### Fixed
- **Install log flood** ([#237](https://github.com/lollonet/snapMULTI/pull/237)) — suppressed Docker Compose per-layer progress output
- **deploy.sh double-logging** ([#238](https://github.com/lollonet/snapMULTI/pull/238)) — info() override by unified-log.sh prevented
- **Pull robustness** ([#239](https://github.com/lollonet/snapMULTI/pull/239)) — cached image map, rate limit kill, MPD PID guard, metadata callback fix
- **Bug hunt** ([#240](https://github.com/lollonet/snapMULTI/pull/240)) — WiFi IP check, meta_mpd crash, cover art server IP, MPD exit handler, Bash 3.2 compat
- **Strict service verification** ([#241](https://github.com/lollonet/snapMULTI/pull/241)) — USB UUID, font check, healthcheck-aware, always-pull policy
- **Install sequence** ([#242](https://github.com/lollonet/snapMULTI/pull/242)) — client verify, idempotent setup, safe DNS
- **Client containers** ([#243](https://github.com/lollonet/snapMULTI/pull/243)) — start via systemd, both-mode detect, fuse-overlayfs gate, client verify exit 1
- **Health check logic** ([#244](https://github.com/lollonet/snapMULTI/pull/244)) — requires running AND healthy (was OR); script hardening

## [0.5.0] — 2026-04-16

### Added
- **Skip existing images** ([#218](https://github.com/lollonet/snapMULTI/pull/218)) — pull-images.sh skips already-pulled images, detects Docker Hub rate limit (429)
- **FIFO health monitoring** ([#224](https://github.com/lollonet/snapMULTI/pull/224)) — diagnostics check FIFO state
- **MPD backup timer** ([#225](https://github.com/lollonet/snapMULTI/pull/225)) — daily backup to boot partition; restored automatically after reflash
- **QUICKSTART.md** ([#226](https://github.com/lollonet/snapMULTI/pull/226)) — one-page getting started guide (README slimmed from 245 to 72 lines)
- **Integration test** ([#232](https://github.com/lollonet/snapMULTI/pull/232)) — /version endpoint + compose validation
- **Issue templates** ([#234](https://github.com/lollonet/snapMULTI/pull/234)) — bug report, feature request, device report

### Changed
- **Dynamic tmpfs sizing** ([#221](https://github.com/lollonet/snapMULTI/pull/221)) — 25% of RAM with 70%/90% monitoring thresholds

### Fixed
- **PIPESTATUS ordering** ([#220](https://github.com/lollonet/snapMULTI/pull/220)) — health checks AND not OR, fuse-overlayfs error handling
- **Pull temp dir race** ([#230](https://github.com/lollonet/snapMULTI/pull/230)) — setup.sh retry on readonly pull failure
- **Trivy arm64 scanning** ([#231](https://github.com/lollonet/snapMULTI/pull/231)) — tidal + client ARM images now scanned
- **Integration test macOS fix** ([#233](https://github.com/lollonet/snapMULTI/pull/233))
- **Shell injection** ([#219](https://github.com/lollonet/snapMULTI/pull/219)) — service name passed via env var instead of string interpolation

## [0.4.1] — 2026-04-13

### Fixed
- **EXIT trap clobber** — pull-images.sh uses RETURN trap only (not EXIT) to avoid clobbering caller's _setup_failure_dump trap. Fixed unbound variable crash on v0.4.0

## [0.4.0] — 2026-04-13

### Added
- **Diagnostic log persistence** — saves dmesg, docker logs, ALSA state to boot partition every 30 min
- **Install checkpoints** — per-phase markers (deps, docker, deploy, setup) enable resume after crash
- **Disk space pre-flight** — checks free space before Docker image pull (2 GB server, 1 GB client)
- **Port availability check** — warns if key ports are in use before starting services
- **Docker Compose v2+ enforcement** — validates version at startup with actionable error
- **Diagnostic dump on failure** — trap collects memory, disk, docker status, dmesg on crash
- **Install duration logging** — total elapsed time shown at completion
- **Advanced install options** — prepare-sd.sh advanced menu (readonly, skip-upgrade, image tag, verbose)
- **Shared modules** ([#217](https://github.com/lollonet/snapMULTI/pull/217)) — extracted pull-images.sh and resource-detect.sh
- **Unified logging** ([#200](https://github.com/lollonet/snapMULTI/pull/200)) — unified-log.sh with timestamps and source IDs
- **Pi Zero 2 W support** — documented in HARDWARE.md (64-bit required, 2.4 GHz only, headless audio)

### Changed
- **Monorepo** ([#212](https://github.com/lollonet/snapMULTI/pull/212)) — merged snapclient-pi into snapMULTI as client/ directory
- **Single-branch CI** ([#211](https://github.com/lollonet/snapMULTI/pull/211)) — develop branch eliminated; :dev images via workflow_dispatch
- **Snapcast pinned to v0.35.0**
- **Modular firstboot** ([#200](https://github.com/lollonet/snapMULTI/pull/200), [#201](https://github.com/lollonet/snapMULTI/pull/201)) — rewritten as orchestrator with extracted modules
- **Silent Docker pulls** — progress output suppressed on success, surfaced on failure
- **Unified version format** — always v0.x.x

### Fixed
- **badaix/snapcast restored on main** ([#210](https://github.com/lollonet/snapMULTI/pull/210)) — santcasp fork accidentally leaked
- **IMAGE_TAG not persisted** ([#202](https://github.com/lollonet/snapMULTI/pull/202)) — deploy.sh writes to .env
- **LOG_SOURCE not reset after module calls**
- **--no-readonly flag positioned before positional config file argument**
- **display.sh validation restored**
- **apt lock race** — explicit _wait_for_apt_lock with SECONDS-based deadline
- **Hostname sanitization** — RFC 1123 max 253 chars
- **prepare-sd.sh sed validation and submodule error handling**
- **install.conf parsing** — _rc helper no longer crashes with set -e
- **USB/I2S HAT conflict** — strip otg_mode=1 and dr_mode=host from config.txt
- **CAKE QoS on clients** — boot-tune.sh skips on client-only systems
- **Stale boot-tune.sh on overlayroot** — install -m 755 always overwrites

## [0.3.26] — 2026-04-07

### Added
- **Hostname in install TUI** — progress screen shows device name for multi-Pi installs
- **Gitleaks secrets detection** — new CI workflow on push/PR
- **Dependabot** — GitHub Actions updates (already configured for Docker)
- **Original release date in metadata** ([#189](https://github.com/lollonet/snapMULTI/pull/189)) — metadata-service exposes `originalDate` from MPD (original release year) alongside `date`

### Changed
- **Python 3.14** — metadata-service bumped from 3.13-slim to 3.14-slim
- **SHA-pinned all GitHub Actions** — 8 workflows hardened against supply chain attacks
- **Client submodule** — Python 3.14, enterprise readiness, autodiscovery fix, Mac runner, deploy removal

### Fixed
- **apt-get upgrade on first boot** — cloud-init's `apt-get update` runs before NTP sync (stale signatures); our `apt-get update` runs after NTP, indices are fresh for upgrade
- **Client SNAPSERVER_HOST cleanup** — discover-server.sh clears hardcoded IPs (including stale 127.0.0.1) at boot for mDNS autodiscovery
- **Firstboot hardening** ([#189](https://github.com/lollonet/snapMULTI/pull/189)) — log apt update/upgrade output (remove `-qq`), stub websockets in metadata test harness

## [0.3.25] — 2026-04-02

### Added
- **Album details in metadata** ([#185](https://github.com/lollonet/snapMULTI/pull/185)) — metadata-service exposes date, genre, track, disc from MPD. Non-MPD sources (Tidal, Spotify, AirPlay) enriched via MusicBrainz lookup with caching. Client display shows `1978 · Reggae · Track 3 · Disc 1`
- **MusicBrainz tag enrichment** ([#185](https://github.com/lollonet/snapMULTI/pull/185)) — all sources get date/genre from MusicBrainz when the source doesn't provide them. Reuses artwork lookup cache — no extra API calls

### Fixed
- **Truncated album names** ([#185](https://github.com/lollonet/snapMULTI/pull/185)) — tidal-meta-bridge truncates long names with unclosed parentheses; metadata-service strips them before MusicBrainz queries

## [0.3.24] — 2026-04-02

### Added
- **Native arm64 CI builds** ([#184](https://github.com/lollonet/snapMULTI/pull/184)) — arm64 builds on Apple Silicon Mac runner with `docker` driver (native speed, was QEMU on raspy)

### Changed
- **Client repo renamed** ([#179](https://github.com/lollonet/snapMULTI/pull/179)) — `rpi-snapclient-usb` → `snapclient-pi` across all docs, submodule, CI, issue templates. GitHub redirect handles old URLs
- **CI: removed deploy step** ([#183](https://github.com/lollonet/snapMULTI/pull/183)) — build workflow no longer SSH-deploys to devices; deployment is via reflash only (live deploy caused fuse-overlayfs corruption on overlayroot)

### Fixed
- **deploy.sh crash on fresh install** ([#178](https://github.com/lollonet/snapMULTI/pull/178)) — `ensure_profile()` used `&&` pattern as last command in function; `set -e` killed the script when `AUTO_UPDATE` was absent (always on fresh installs)
- **Artwork lookup failures cached forever** ([#180](https://github.com/lollonet/snapMULTI/pull/180)) — failed MusicBrainz/iTunes lookups now expire after 1 hour; sources like Tidal that never provide artwork get retried instead of permanent empty cache. Thread-safe cache eviction with `dict.pop`
- **MPD zeroconf registration** ([#183](https://github.com/lollonet/snapMULTI/pull/183)) — added D-Bus socket mount so MPD can register via Avahi; mobile apps (MPDroid, Cantata) now auto-discover the server

## [0.3.22] — 2026-03-31

### Added
- **Periodic snapserver re-discovery** ([#165](https://github.com/lollonet/snapMULTI/pull/165)) — systemd timer re-discovers snapserver every 5min via mDNS; snapclient restarts only when server IP actually changes (eth↔wlan failover)
- **MPD database backup on SD card** ([#164](https://github.com/lollonet/snapMULTI/pull/164)) — `prepare-sd.sh` includes pre-built `mpd.db` if present, avoiding full NFS library rescan (~7h → seconds) on reflash
- **SECURITY.md** — vulnerability disclosure policy via GitHub Security Advisories
- **Post-install summary screen** ([#170](https://github.com/lollonet/snapMULTI/pull/170)) — shows Snapweb/myMPD URLs with detected IP on HDMI before reboot
- **RAM validation** ([#170](https://github.com/lollonet/snapMULTI/pull/170)) — warns if memory reserves exceed available RAM during deploy
- **Tmpfs usage monitoring** — boot-tune logs syslog warning when overlayroot tmpfs >80% full
- **Music source menu guidance** ([#171](https://github.com/lollonet/snapMULTI/pull/171)) — hint text helps beginners choose the right option
- **prepare-sd parity CI check** ([#171](https://github.com/lollonet/snapMULTI/pull/171)) — validates bash and PowerShell scripts copy the same files

### Changed
- **Healthchecks upgraded** — snapserver tests Snapweb HTTP (was `pidof`), tidal checks `speaker_controller` process
- **CAKE QoS on all interfaces** — applies to both eth and wlan for failover; detects link speed for bandwidth hint
- **BuildKit cache mounts** on all Dockerfiles — faster rebuilds for apk, apt, pip, uv, cmake
- **Shared Docker install** ([#168](https://github.com/lollonet/snapMULTI/pull/168)) — client setup.sh uses `install_docker_apt()` from shared script
- **deploy.sh** — `ensure_profile()` helper deduplicates COMPOSE_PROFILES management

### Fixed
- **MPD database purge on reboot** ([#167](https://github.com/lollonet/snapMULTI/issues/167)) — entrypoint waits for actual music files before starting MPD; skips forced rescan when pre-built db exists; boot-tune restarts MPD if bind-mount is stale
- **discover-server.sh missing from SD card** — was never added to prepare-sd copy chain
- **NFS mount options** — added `rsize=32768` for read performance; removed redundant `wsize` on ro mount; removed `x-systemd` options that caused boot hangs
- **SMB username sanitization** — prepare-sd.sh now uses shared `sanitize_smb_user()` with user feedback
- **meta_tidal.py** — JSON decode errors logged instead of silently swallowed
- **Boot-tune logging** — CPU governor and USB autosuspend failures logged via syslog

### Security
- **DAC_OVERRIDE scoped** ([#169](https://github.com/lollonet/snapMULTI/pull/169), closes [#146](https://github.com/lollonet/snapMULTI/issues/146)) — only FIFO-writing containers get DAC_OVERRIDE; mympd, mpd, metadata no longer have it
- **apparmor:unconfined removed** from default security anchor — only on containers needing D-Bus

## [0.3.17] — 2026-03-29

### Added
- **Hardware watchdog** ([#161](https://github.com/lollonet/snapMULTI/pull/161)) — `bcm2835_wdt` kernel module + `RuntimeWatchdogSec=60` auto-reboots on system hang; no more manual power cycles on headless Pis
- **MPD log rotation** ([#161](https://github.com/lollonet/snapMULTI/pull/161)) — `log_file_max_size 1048576` caps MPD log at 1MB (was: unbounded growth filling SD card)
- **Artwork cache cleanup** ([#161](https://github.com/lollonet/snapMULTI/pull/161)) — boot-tune removes cached artwork older than 30 days
- **Cross-mode parity** ([#160](https://github.com/lollonet/snapMULTI/pull/160)) — overlayroot, avahi hardening, boot-tune service, and SSH key persistence now work in ALL install modes (was: some features client-only or server-only)
- **NTP sync before apt** ([#159](https://github.com/lollonet/snapMULTI/pull/159)) — wait for system clock sync before package operations; Pi has no RTC and apt signature verification fails with stale clock
- **CI quality gates** ([#155](https://github.com/lollonet/snapMULTI/pull/155)) — ruff check + format, hadolint for all Dockerfiles, server pre-push hook matching remote CI

### Changed
- **vm.swappiness=10** ([#161](https://github.com/lollonet/snapMULTI/pull/161)) — keeps audio buffers in RAM instead of swapping (was: default 60)
- **Healthcheck interval 30s** ([#161](https://github.com/lollonet/snapMULTI/pull/161)) — faster failure detection (was: 60s, up to 3 min to detect)
- **Shared system-tune.sh functions** ([#160](https://github.com/lollonet/snapMULTI/pull/160)) — `tune_avahi_daemon()`, `setup_readonly_fs()`, `install_boot_tune_service()` replace inline duplicates in deploy.sh and setup.sh

### Fixed
- **apt-get upgrade exit code masked** ([#159](https://github.com/lollonet/snapMULTI/pull/159)) — `| tail -3` hid failures; now checks exit code and logs warning
- **fuse-overlayfs fatal in both mode** ([#159](https://github.com/lollonet/snapMULTI/pull/159)) — install failure now aborts (was: continued without it, then Docker fails on overlayroot)
- **deploy.sh fuse-overlayfs ordering** ([#159](https://github.com/lollonet/snapMULTI/pull/159)) — install package before writing to daemon.json (was: Docker failed to start on fresh deploy)
- **boot-tune.sh missing from SD** ([#158](https://github.com/lollonet/snapMULTI/pull/158)) — added to prepare-sd copy chain for all modes
- **prepare-sd username parse** ([#157](https://github.com/lollonet/snapMULTI/pull/157)) — `name:` regex matched `hostname:` before `users:` in cloud-init user-data
- **Avahi restart only on change** ([#160](https://github.com/lollonet/snapMULTI/pull/160)) — `tune_avahi_daemon()` no longer restarts unconditionally on every deploy

## [0.3.16] — 2026-03-29

### Added
- **Shared system-tune.sh** ([#147](https://github.com/lollonet/snapMULTI/pull/147)) — shared system tuning module eliminates configuration drift between server and client (CPU governor, USB autosuspend, WiFi power save, Docker daemon.json)
- **apt upgrade on first boot** ([#147](https://github.com/lollonet/snapMULTI/pull/147)) — security patches applied during first boot, before overlayroot freezes the filesystem
- **USB drive auto-mount** ([#147](https://github.com/lollonet/snapMULTI/pull/147)) — headless Debian doesn't auto-mount USB; firstboot.sh now mounts and adds fstab entry
- **INSTALL.it.md** — Italian translation of installation guide

### Fixed
- **Docker image pull retry** ([#147](https://github.com/lollonet/snapMULTI/pull/147)) — 3 attempts with backoff (0s/10s/30s) prevents DNS failures during firstboot from bricking the install
- **verify_services() timeout** ([#147](https://github.com/lollonet/snapMULTI/pull/147)) — uses MPD_START_PERIOD from .env (up to 300s for NFS) instead of hardcoded 60s
- **Docker storage driver hardening** ([#147](https://github.com/lollonet/snapMULTI/pull/147)) — validates fuse-overlayfs before wiping Docker data; skips read-only mode on failure instead of bricking
- **FIFO path** ([#147](https://github.com/lollonet/snapMULTI/pull/147)) — deploy.sh creates `mpd_fifo` (was `snapcast_fifo`, mismatched config)
- **write_version ordering** ([#147](https://github.com/lollonet/snapMULTI/pull/147)) — .env version written before containers start (metadata display), .version file after verify (correctness)
- **fuse-overlayfs ordering** ([#147](https://github.com/lollonet/snapMULTI/pull/147)) — daemon.json gets `--fuse-overlayfs` after package is installed, not before Docker starts
- **apt lock wait** ([#147](https://github.com/lollonet/snapMULTI/pull/147)) — waits for unattended-upgrades to finish before apt operations
- **CAKE boot hook** — iptables DSCP rules now persist across reboots (were lost, only CAKE persisted); added PATH for networkd-dispatcher
- **Verbose boot** — remove `quiet splash fbcon=map:9` from cmdline.txt so kernel messages are visible during boot
- **Local snapserver detection** — client discover-server.sh prefers 127.0.0.1 when colocated server is running
- **prepare-sd.sh verification** — shows WiFi SSID, server/client versions, checks install-docker.sh; clearer cmdline.txt message

### Changed
- **Client submodule cleanup** ([#148](https://github.com/lollonet/snapMULTI/pull/148)) — removed obsolete client scripts (prepare-sd.sh, install/firstboot.sh) superseded by unified installer; updated client docs to reflect snapMULTI server dependency
- **Server docs updated** ([#148](https://github.com/lollonet/snapMULTI/pull/148)) — fixed security matrix, container count, CI runner architecture, Snapcast version; SSOT compliance; Italian translations synced

## [0.3.14] — 2026-03-25

### Added
- **Network QoS for Snapcast** ([#144](https://github.com/lollonet/snapMULTI/pull/144)) — `deploy.sh` sets up CAKE qdisc with DSCP EF marking on Snapcast ports 1704/1705, prioritizing audio packets over bulk file transfers to prevent bufferbloat-induced glitches. Persists across reboots via iptables-save and networkd-dispatcher hook

### Fixed
- **CPU governor and USB autosuspend tuning** ([#139](https://github.com/lollonet/snapMULTI/pull/139)) — `deploy.sh` sets CPU governor to `performance` and disables USB autosuspend to prevent audio glitches; settings persist via `/etc/default/cpufrequtils` and udev rule
- **Tidal SIGTERM forwarding** ([#143](https://github.com/lollonet/snapMULTI/pull/143)) — tidal-connect entrypoint now properly forwards SIGTERM to child processes with trap disarming to prevent re-entrancy; metadata bridge has circuit breaker after 10 consecutive failures
- **First-boot client file validation** ([#142](https://github.com/lollonet/snapMULTI/pull/142)) — `firstboot.sh` validates critical client files (setup.sh, audio-hats/, display scripts) exist before proceeding; copy errors now surface instead of being silenced
- **SSH key cleanup and grep-c bug** ([#141](https://github.com/lollonet/snapMULTI/pull/141)) — deploy workflow SSH key file cleaned up via trap; fixed progress.sh `grep -c` producing double output on empty input
- **Council audit batch 4** ([#145](https://github.com/lollonet/snapMULTI/pull/145)) — 8 cross-cutting fixes: missing Dockerfile.metadata in PowerShell SD prep, headless display false positive, visible docker pull errors, SSH StrictHostKeyChecking hardened, boot partition validation, snapcast SHA fetch guard, credential scrub fallback
- **Deploy SSH hardened** ([#145](https://github.com/lollonet/snapMULTI/pull/145)) — `StrictHostKeyChecking=accept-new` instead of `=no` in deploy workflow

### Changed
- **Client submodule updated to v0.2.19** ([#140](https://github.com/lollonet/snapMULTI/pull/140)) — HAT mixer auto-detection, CPU governor tuning, display.sh safety fixes

## [0.3.13] — 2026-03-23

### Changed
- **Resource profiles optimized from production measurements** ([#124](https://github.com/lollonet/snapMULTI/pull/124)) — re-baselined all Docker CPU and memory limits using live `docker stats` from snapvideo (Pi 4 8GB) and snapdigi (Pi 4 2GB). Key changes: shairport-sync 128M→64M (measured: 18M), mympd 128M→64M (measured: 8M), snapserver 256M→192M (measured: 87M). Spotify kept at 256M (measured active: ~180M). Reduces standard profile total from 1,280M to 1,056M
- **Client profile names harmonized** — renamed `low/medium/high` to `minimal/standard/performance` to match server naming convention
- **MPD config best practices** ([#130](https://github.com/lollonet/snapMULTI/pull/130), [#129](https://github.com/lollonet/snapMULTI/issues/129)) — audited `mpd.conf` against official docs: replaced legacy `db_file` with `database{}` block (`path` + `compress "yes"`), added required `encoder "lame"` to httpd output (was broken without it), removed invalid `filter` option from simple plugin, raised `max_connections` 10→30, added `connection_timeout "60"`, added `zeroconf_name`, fixed `log_level` from undocumented `"notice"` to `"default"`

### Added
- **Hardware compatibility matrix** ([#124](https://github.com/lollonet/snapMULTI/pull/124)) — `docs/HARDWARE.md` now includes tables for all Pi model × role combinations (server, client, both mode) with memory limit totals and compatibility status
- **Watchtower resource limits** — watchtower container now has 64M memory / 0.25 CPU limits (was unlimited)

### Fixed
- **MPD incomplete library scan** ([#128](https://github.com/lollonet/snapMULTI/pull/128)) — three root causes addressed: (1) `filter "~.*"` → `"._*"` in `mpd.conf` to correctly target only macOS resource forks via standard fnmatch instead of an undocumented/over-aggressive pattern; (2) `log_level "notice"` → `"info"` so file-skip and decode errors become visible; (3) new `mpd-entrypoint.sh` runs `mpc update --wait` after startup so the container is only healthy after the full library scan completes. Default `MPD_MEM_LIMIT` raised 256M → 512M to prevent OOM mid-scan on large FLAC libraries
- **Metadata build block removed** — removed stale `build:` block from metadata service in `docker-compose.yml` (leftover from development; production uses pre-built image)
- **README container count** — clarified total container count (seven on ARM including tidal-connect)
- **Tidal metadata C1 escape regex** ([#126](https://github.com/lollonet/snapMULTI/pull/126)) — `strip_escapes` in `tidal-meta-bridge.sh` was missing `]` (0x5D) from the C1 character range; fixed `[A-Za-z@\[\\^_]` → `[@-_]` to cover the complete C1 set (0x40–0x5F)
- **CI deploy tmpfs exhaustion** ([#123](https://github.com/lollonet/snapMULTI/pull/123)) — reordered deploy steps to prevent overlayroot tmpfs from filling up during image pull + bake
- **MPD scan failure silently swallowed** ([#134](https://github.com/lollonet/snapMULTI/pull/134)) — `mpd-entrypoint.sh` used `|| true` on `mpc update --wait`, hiding NFS timeouts and permission errors. Now logs `WARNING: library scan failed or incomplete` to `docker logs mpd`
- **First-boot client setup crash** ([#136](https://github.com/lollonet/snapMULTI/pull/136)) — `prepare-sd.sh` was not copying `display.sh` and `display-detect.sh` to the boot partition; `setup.sh` failed at line 1108 with "No such file or directory" on first boot. Fixed in both bash and PowerShell (`prepare-sd.ps1`) variants

### Removed
- **Dead YAML anchors** — removed unused `x-resources-minimal`, `x-resources-standard`, `x-resources-performance` from `docker-compose.yml` (defined but never referenced by any service)

### Documentation
- **Docs coherence audit** ([#125](https://github.com/lollonet/snapMULTI/pull/125), [#127](https://github.com/lollonet/snapMULTI/pull/127)) — synced Italian translations, fixed stale references, corrected container counts across all docs

### CI/CD
- **PR workflows switched to GitHub-hosted runners** — `validate.yml`, `build-test.yml`, and `claude-code-review.yml` now run on `ubuntu-latest` instead of offline `snapcast-runner`
- **Docker build path filtering** ([#132](https://github.com/lollonet/snapMULTI/pull/132)) — `build-test.yml` now only triggers when Dockerfiles or their COPYed files change (skips doc-only PRs)
- **Claude review allowedTools fix** ([#131](https://github.com/lollonet/snapMULTI/pull/131)) — broadened `Bash(gh *)` to include `printf`, `echo`, `cat` so piped commands aren't silently denied

### Maintenance
- **Client submodule update** — locale setup (`C.UTF-8`), removed unused `gnupg` and `git` packages
- **Client submodule update** ([#135](https://github.com/lollonet/snapMULTI/pull/135)) — headless profile fix: `setup.sh` respects display detection, `audio-visualizer` gated under `framebuffer` profile (saves 128-256M RAM on headless Pis)

## [0.3.12] — 2026-03-19

### Fixed
- **Headless Pi detection with vc4-kms-v3d** ([#122](https://github.com/lollonet/snapMULTI/pull/122)) — `has_display()` in `firstboot.sh` now correctly detects headless Pi 4 when HDMI is unplugged. Previously returned "display present" when DRM status files existed but all said "disconnected" (vc4-kms-v3d creates `/dev/fb0` even without HDMI). New `found_status` flag distinguishes "no DRM files" (old firmware, assume display) from "all disconnected" (headless)
- **DAC+ clock race on EEPROM-less boards** ([snapclient-pi#97](https://github.com/lollonet/snapclient-pi/pull/97)) — clone/EEPROM-less PCM5122 boards were misdetected as DAC+ Pro (floating GPIO3), causing master clock race with no audio. ALSA and I2C fallback detection now uses `hifiberry-dacplus-std` overlay (Pi as clock master). Adds `dtparam=i2c_arm=on` for I2C-based HATs. New manual menu option for Standard/clone boards

### Added
- **Boot-time display detection** ([snapclient-pi#97](https://github.com/lollonet/snapclient-pi/pull/97)) — new systemd oneshot service checks HDMI on every boot and reconciles Docker Compose profiles. Headless Pis now run only `snapclient` (saves ~300 MB RAM). `audio-visualizer` gated under `framebuffer` profile alongside `fb-display`

### Maintenance
- **Client submodule update** — DAC clock race fix + boot-time display detection (see [snapclient-pi#97](https://github.com/lollonet/snapclient-pi/pull/97))

## [0.3.11] — 2026-03-18

### Added
- **Snapcast upstream migration** ([#121](https://github.com/lollonet/snapMULTI/pull/121)) — migrated snapserver from santcasp fork to official badaix/snapcast upstream (v0.35.0). Multi-stage Dockerfile builds from source with Snapweb bundled. Removes fork dependency

### Fixed
- **Locale errors during install** ([#120](https://github.com/lollonet/snapMULTI/pull/120)) — set `C.UTF-8` as default locale in `firstboot.sh`; removes unused `gnupg` package install that was failing on minimal images
- **CI deploy secret resolution** — pass `HOST` as explicit `workflow_call` secret in `deploy.yml` (fixes environment-scoped secret not propagating to reusable workflows)

### Maintenance
- **Client submodule update** ([#119](https://github.com/lollonet/snapMULTI/pull/119)) — latest main

## [0.3.10] — 2026-03-16

### Added
- **Complete Installation Guide** ([#117](https://github.com/lollonet/snapMULTI/pull/117)) — `docs/INSTALL.md` covers all platforms (macOS/Linux/Windows): Raspberry Pi Imager steps, SD card remount procedure, Git prerequisites, `prepare-sd.sh`/`prepare-sd.ps1` usage with menu screenshots, first-boot expectations, verification commands, adding speaker Pis, troubleshooting table, and network port reference

### Fixed
- **Silent failures in plugin and metadata service** ([#118](https://github.com/lollonet/snapMULTI/pull/118)) — replaced bare `except:` / `except Exception: pass` with specific exception types and logging in `meta_mpd.py` (reconnect, GetMetadata) and `metadata-service.py` (hostname resolution); implemented `GetMetadata` command in `meta_mpd.py` (was returning an error stub)

### Security
- **Container hardening** ([#116](https://github.com/lollonet/snapMULTI/pull/116)) — removed unnecessary `SETUID`/`SETGID` capabilities from default security profile; added `no-new-privileges`, `cap_drop: ALL`, `read_only`, and tmpfs to `watchtower`; added `USER 1000` to `Dockerfile.metadata` (defense-in-depth when compose `user:` is not specified)

### CI/CD
- **GitHub Environments for deploy** ([#115](https://github.com/lollonet/snapMULTI/pull/115)) — `HOST` secret moved from repo-level to environment-scoped (`snapvideo`); `deploy.yml` declares `environment:` so GitHub resolves the secret automatically; added concurrency group (`cancel-in-progress: false`) to queue rather than cancel in-progress deploys

### Maintenance
- **Client submodule v0.2.10** — see [snapclient-pi CHANGELOG](https://github.com/lollonet/snapclient-pi/blob/main/CHANGELOG.md)

## [0.3.9] — 2026-03-16

### Fixed
- **MPD healthcheck timeout on large NFS/SMB libraries** ([#112](https://github.com/lollonet/snapMULTI/pull/112)) — increase `MPD_START_PERIOD` default from 60s to 300s; switch mympd dependency to `service_started` (mympd retries MPD connection internally)
- **MPD: Avahi mDNS errors** ([#111](https://github.com/lollonet/snapMULTI/pull/111)) — bind-mount `/run/avahi-daemon/socket` into MPD container; eliminates `Failed to create Avahi client: Daemon not running` log spam
- **MPD: macOS dotfiles indexed** ([#111](https://github.com/lollonet/snapMULTI/pull/111)) — add `database { filter "~.*" }` to `mpd.conf`; excludes `._filename` resource fork files from the database (~48% noise reduction on NFS shares from macOS)
- **Tidal metadata garbage characters** ([#113](https://github.com/lollonet/snapMULTI/pull/113)) — `speaker_controller_application` runs in 8-bit terminal mode; tmux encoded C1 control chars (U+0080–U+009F) as `~@~X` in captures (e.g. `~@~S` in artist names like `CCCP – Fedeli Alla Linea`). Add `strip_escapes()` to sanitize capture-pane output before parsing

### Changed
- **CI deploy: persist through overlayroot** ([#110](https://github.com/lollonet/snapMULTI/pull/110)) — `deploy.yml` now bakes config, MPD database, myMPD state, Docker image index, and new image layers to the SD card lower layer (`/media/root-ro`) between `docker compose down` and `up`. Uses bind-mount technique (safe with active overlayfs) so deployments survive Pi reboots. MPD db bake avoids full NFS/SMB rescan on reboot (incremental update only). Verified by checking `SNAPMULTI_VERSION` in baked `.env` before starting containers.

### Documentation
- **Hardware Buying Guide — US/UK pricing** — Replaced Italian market EUR prices with Amazon US (USD) and The Pi Hut UK (GBP). Added **Budget Alternative — InnoMaker PCM5122 (~$195)**: Pi 4 2GB + InnoMaker HiFi DAC HAT (~$110) and Pi 3B+ + InnoMaker DAC Mini HAT (~$81). All prices verified March 2026 from pishop.us, thepihut.com, and inno-maker.com. Italian translation updated with Amazon IT equivalent (~€175).

### Maintenance
- **Client submodule v0.2.7** — snapclient built from badaix/snapcast upstream
- **Client submodule v0.2.6** — 15 audio HATs now fully supported with EEPROM + ALSA auto-detection (new: HiFiBerry AMP2, HiFiBerry DAC+ ADC Pro, Innomaker DAC PRO ES9038Q2M, Waveshare WM8960); status bar shows both client and server versions simultaneously (e.g. `v0.2.6 / srv 0.3.8`)

## [0.3.8] — 2026-03-10

### Added
- **TCP audio input** — Source 5 accepts raw PCM streams from any device on the LAN (port 4953). Re-enables ffmpeg and Android streaming (BubbleUPnP, Termux) into the multi-room system

## [0.3.7] — 2026-03-09

### Added
- **Server info broadcast** ([#102](https://github.com/lollonet/snapMULTI/pull/102)) — metadata-service pushes server version, Snapcast version, connected client count, and active streams to all display clients every ~60s via WebSocket. Bottom bar on fb-display now shows server version alongside IP address. New `server_info` WS message type; `/health` now reports `server_info` capability
- **Client submodule v0.2.4** — fb-display shows server version in status bar, falls back to `APP_VERSION` env var

## [0.3.6] — 2026-03-09

### Added
- **WebSocket stream subscription** — Controller clients (e.g. snapCTRL) can now subscribe by stream name with `{"subscribe_stream": "Spotify"}` and receive metadata without per-client volume injection. `/health` now returns `{"status":"ok","capabilities":["subscribe_stream"]}`
- **Automatic updates** ([#76](https://github.com/lollonet/snapMULTI/issues/76)) — Opt-in automatic Docker image updates via Watchtower (`AUTO_UPDATE=true` in `.env`). New `scripts/update.sh` for config/script updates from GitHub releases without git. Works on both SD-card installs and git-cloned setups. Major version changes blocked for safety

### Changed
- **Tidal Connect deploy via COMPOSE_PROFILES** ([#99](https://github.com/lollonet/snapMULTI/pull/99)) — ARM detection now writes `COMPOSE_PROFILES=tidal` to `.env`; `deploy.sh` and CI no longer need architecture-specific service lists. `pull_images()` and `verify_services()` derive active services from compose config dynamically
- **Client submodule v0.2.3** — ALSA & network tuning with WiFi/Ethernet auto-detection, Docker image pull fix, discover-server install guard

### Fixed
- **Service health check timing** — Added 5-second initial wait in `verify_services` after `docker compose up -d`, preventing false-healthy results while containers are still in the "starting" state

## [0.3.5] — 2026-03-07

### Fixed
- **Avahi hostname collision hardening** ([#98](https://github.com/lollonet/snapMULTI/pull/98)) — Pin `host-name` in avahi-daemon.conf and restrict `allow-interfaces` to physical NICs (exclude docker0/br-*/veth*), preventing transient devices from claiming the hostname and breaking Tidal Connect mDNS

### Changed
- **CI deploys to snapvideo** — Deploy workflow targets `/opt/snapmulti` on snapvideo instead of raspy

### Maintenance
- **Client submodule v0.2.2** — mDNS auto-discovery for server failover in fb-display, LAN IP + snapserver shown in bottom bar, avahi-utils install fix

## [0.3.4] — 2026-03-05

### Documentation
- **Complete project documentation suite** ([#96](https://github.com/lollonet/snapMULTI/pull/96)) — 11 requirement documents, 2 architecture documents (deployment, security), 4 Architecture Decision Records (host networking, FIFO routing, read-only containers, metadata service), CONTROL.yaml and .bass-ready marker. Fixed stale TECH and WBS docs

### Maintenance
- **Client submodule v0.2.1** — Metadata host derives from snapserver host; mDNS discovery on boot; big-endian framebuffer support

## [0.3.3] — 2026-03-04

### Performance
- **Metadata-service CPU reduction (-79%)** ([#95](https://github.com/lollonet/snapMULTI/pull/95)) — Smart MusicBrainz rate limiter (sleeps only remaining time instead of unconditional 1.1s), poll interval increased from 2s to 3s, client-stream map rebuild skipped when unchanged, redundant `socket.error`/`socket.timeout` exception handlers cleaned up
- **Tidal metadata bridge optimization (-73% CPU)** ([#95](https://github.com/lollonet/snapMULTI/pull/95)) — Rewrote main loop to use bash builtins instead of grep/sed/tr pipelines, reducing ~37 subprocess forks/sec to ~4
- **Healthcheck intervals** ([#95](https://github.com/lollonet/snapMULTI/pull/95)) — Increased from 30s to 60s across all 7 services, halving process spawns from healthchecks
- **Progress bar rendering** ([#95](https://github.com/lollonet/snapMULTI/pull/95)) — Replaced character-by-character loop with `printf -v` (eliminates 100 iterations per render)

## [0.3.2] — 2026-03-04

### Added
- **Per-image pull progress** ([#91](https://github.com/lollonet/snapMULTI/pull/91)) — First-boot deploy now pulls Docker images one at a time with `Pulling <service> (N/M)` progress on HDMI. `firstboot.sh` pipes deploy output through a filter that forwards key milestones to the TUI while logging everything

### Fixed
- **Fresh deploy bind-mount failures** ([#89](https://github.com/lollonet/snapMULTI/pull/89)) — Removed 3 dev-only bind mounts (`meta_tidal.py`, `common.sh`, `tidal-meta-bridge.sh`) from `docker-compose.yml` that referenced host scripts not present on fresh SD card deploys. Files are already baked into Docker images via COPY in Dockerfiles
- **First-boot network recovery** ([#90](https://github.com/lollonet/snapMULTI/pull/90)) — Replaced single WiFi kick with 4-stage escalating recovery: WiFi activation at 30s, NetworkManager restart at 60s, fallback DNS at 90s, interface bounce at 120s. Added diagnostic logging so network failures produce actionable output in the install log
- **firstboot.sh crash under `set -u`** — Unset `PROGRESS_LOG` variable caused immediate crash when firstboot.sh sourced `progress.sh` under strict mode
- **Tidal resource limits missing from hardware profiles** — `deploy.sh` was not generating CPU/memory limits for the tidal-connect container, leaving it unconstrained on resource-limited Pi hardware
- **Tidal CPU limit quoting** — Unquoted CPU limit value caused inconsistent YAML parsing in `docker-compose.yml` across different Docker Compose versions
- **Division by zero in progress.sh** — Weight calculation crashed when all weights summed to zero (edge case during early initialization)
- **meta_mpd duplicate stdin watchers** ([#94](https://github.com/lollonet/snapMULTI/pull/94)) — `my_connect()` added a new `GLib.io_add_watch` on stdin for every MPD reconnect without a guard. After N reconnects, `io_callback` fired N times per stdin event, causing `"can't concat NoneType to bytes"` errors. Fixed by tracking watcher via `_stdin_watch_id`, cleaning up GLib sources on disconnect, and guarding non-blocking read

### Maintenance
- **Client submodule v0.1.9** — Updated `client/` submodule

## [0.3.1] — 2026-03-02

### Fixed
- **Metadata-service MPD connection resilience** ([#88](https://github.com/lollonet/snapMULTI/pull/88)) — When MPD is unresponsive (e.g. during NFS database scan on startup), the 5s connect timeout blocked the executor thread every poll cycle, slowing all metadata streams. Added 10s cooldown between reconnection attempts, reduced timeout to 2s, and periodic "still unreachable" logging every 30s

## [0.3.0] — 2026-03-01

### Added
- **Status script** ([#27](https://github.com/lollonet/snapMULTI/issues/27)) — `scripts/status.sh` provides a one-command health overview: container health with memory usage, stream status, and connected clients with volume levels. Auto-detects install type (server, client, or both)
- **Snapweb UI** — Web interface at `http://<server>:1780` for managing speakers, switching sources, and adjusting volume. Built from [snapcast/snapweb](https://github.com/snapcast/snapweb) v0.9.3 and bundled into the snapserver container
- **Hardware mixer for volume-independent spectrum** ([#48](https://github.com/lollonet/snapMULTI/issues/48)) — New `MIXER` env var lets snapclient use the DAC's hardware mixer (`hardware:Digital`) so the ALSA loopback receives full-scale PCM regardless of volume. Spectrum bars stay consistent at any volume level. Defaults to `software` for compatibility; set `MIXER=hardware:<element>` to enable (run `amixer scontrols` to find your element name)

### Fixed
- **Tidal Connect metadata** ([#78](https://github.com/lollonet/snapMULTI/issues/78)) — Replaced non-functional WebSocket approach with file-based metadata. `speaker_controller_application` (ifi companion binary) now runs in tmux, `tidal-meta-bridge.sh` scrapes its TUI output and writes JSON to `/audio/tidal-metadata.json`, which `meta_tidal.py` polls and forwards to snapserver. Removes `websocket-client` dependency from snapserver image
- **Controlscript buffer overflow protection** ([#68](https://github.com/lollonet/snapMULTI/pull/68)) — Added safety caps to stdin and pipe buffers in `meta_tidal.py` (64 KB) and `meta_shairport.py` (64 KB stdin + 1 MB pipe) to prevent unbounded memory growth from malformed or excessive input
- **MPD database corruption on first run** — `deploy.sh` was pre-creating an empty `mpd.db` with `touch`; MPD interprets a 0-byte file as corrupt and refuses to scan. Now removes stale files so MPD creates a valid database on first start
- **Client metadata discovery** — Updated client submodule with METADATA_HOST mDNS auto-discovery so clients find the server's metadata service without manual IP configuration
- **Client-only install screen bouncing** — When `firstboot.sh` called `setup.sh`, both scripts rendered competing progress displays to `/dev/tty1`. Now `firstboot.sh` sets `PROGRESS_MANAGED=1` so `setup.sh` defers to the parent's display
- **setup.sh Unicode on framebuffer** — Replaced Unicode box-drawing chars, Braille spinners, and emoji with ASCII-safe equivalents (`#/-`, `[x]/[>]/[ ]`, `|/-\`) for Linux console PSF fonts
- **Source numbering in snapserver.conf** — Commented-out example sources were numbered 6–9 instead of 5–8, mismatching `docs/SOURCES.md`
- **Shell option restoration in deploy.sh** — `$old_nullglob` changed to `eval "$old_nullglob"` for proper `shopt` state restoration in `detect_music_library()`
- **Metadata-service socket leak** ([#87](https://github.com/lollonet/snapMULTI/pull/87)) — Fixed file descriptor leak in `_create_socket()` when `connect()` fails; socket is now closed in the error path
- **Metadata-service poll loop resilience** ([#87](https://github.com/lollonet/snapMULTI/pull/87)) — Added consecutive error counter (30 threshold) to `poll_loop()` so the service exits instead of spinning forever on persistent failures; Docker's restart policy then recovers it

### Security
- **Container vulnerability scanning** ([#36](https://github.com/lollonet/snapMULTI/issues/36)) — [Trivy](https://trivy.dev/) scans all Docker images for CRITICAL and HIGH CVEs. Results uploaded to GitHub Security tab (SARIF). Runs after every image build, weekly on Monday, and on manual dispatch
- **Read-only containers** — All 10 containers now run with `read_only: true` and tmpfs for writable paths. Tidal Connect required ALSA system config include (`</usr/share/alsa/alsa.conf>`) since `ALSA_CONFIG_PATH` replaces the entire config search
- **Non-root containers** — 9 of 10 containers now run as uid 1000 with `cap_drop: ALL` and selective `cap_add`. Device access via `group_add` (audio=29, video=44). Only tidal-connect remains root (proprietary binary)

### Maintenance
- **CI: all workflows on self-hosted runner** — Claude Code Review and Claude Code helper workflows moved from `ubuntu-latest` to `snapcast-runner` for consistent CI environment
- **CI: actions/setup-python 5.6.0 → 6.2.0** ([#81](https://github.com/lollonet/snapMULTI/pull/81)) — Node.js 22 runtime, improved caching
- **Snapweb builder: Node 22 → Node 24 LTS** ([#85](https://github.com/lollonet/snapMULTI/pull/85)) — Active LTS (Oct 2025–Apr 2028), same Alpine base

## [0.2.0] — 2026-02-19

### Added
- **Tidal Connect metadata** — Track info (title, artist, album, artwork, duration) now displayed for Tidal streams
  - `meta_tidal.py` controlscript connects to tidal-connect's WebSocket API (port 8888)
  - Follows the same Snapcast controlscript pattern as MPD, AirPlay, and Spotify
  - All four active sources now have full metadata support
- **Centralized metadata service** — Cover art and track info now served by the snapMULTI server instead of per-client
  - Server-side `metadata-service` container (ports 8082 WS, 8083 HTTP) polls Snapserver JSON-RPC for all streams
  - Multi-stream support: clients subscribe with `{"subscribe": "CLIENT_ID"}` to receive their stream's metadata
  - Cover art chain: MPD embedded → iTunes → MusicBrainz → Radio-Browser (fetched once, shared across all clients)
  - Artwork served via built-in HTTP server (`/artwork/{filename}`, `/metadata.json`, `/health`)
  - Clients no longer need metadata-service or nginx containers (2 fewer containers per client)
  - New Docker image: `lollonet/snapmulti-metadata:latest` (amd64 + arm64)
- **Music source configuration** — `prepare-sd.sh` now asks where your music is (streaming only, USB drive, NFS/SMB network share, or manual)
  - NFS and SMB shares are mounted automatically on first boot with fstab persistence
  - Streaming-only mode skips music library scan (no confusing "not found" warning)
  - Input sanitization for all network share parameters
  - Windows `prepare-sd.ps1` has the same music source menu
- **Unified installer** — Single `prepare-sd.sh` supports both server and client installation
  - 3-option menu: Audio Player (client), Music Server (server), Server + Player (both)
  - `install.conf` marker controls what `firstboot.sh` installs on the Pi
  - Client repo (`snapclient-pi`) added as git submodule at `client/`
- **Windows SD card preparation** — `prepare-sd.ps1` PowerShell script with same functionality as `prepare-sd.sh`
  - Auto-detects bootfs drive, 3-option menu, patches cloud-init, safe eject
- **Git installed on Pi** — `deploy.sh` and `firstboot.sh` install `git` so users can `git pull` for updates
- **Headless client detection** — `firstboot.sh` detects HDMI via `/dev/fb0` and DRM status files
  - Display attached: full visual stack (snapclient + visualizer + cover art display)
  - Headless: audio-only (snapclient container only)
- **Both mode** — Server + Player on the same Pi with no port conflicts
  - Server at `/opt/snapmulti/` (host networking: 1704, 1705, 1780, 6600, 8082, 8083, 8180), client at `/opt/snapclient/` (bridge networking: 8080, 8081)
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
- **Registry migration** — Custom images (`snapmulti-{server,airplay,mpd,tidal}`) moved from GitHub Container Registry (`ghcr.io/lollonet/`) to Docker Hub (`lollonet/`) for faster pulls on Pi hardware ([#64](https://github.com/lollonet/snapMULTI/pull/64))
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
- **prepare-sd.sh** — Support Bookworm cloud-init user-data and snapclient-pi boot pattern
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
