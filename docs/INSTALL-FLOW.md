🇬🇧 **English** | 🇮🇹 [Italiano](INSTALL-FLOW.it.md)

# Installation Flow

What happens between "flash the SD card" and "the appliance is running" — at a level useful for technical users, not exhaustive internals. For the beginner walk-through see [INSTALL.md](INSTALL.md); for operational customisation see [ADVANCED.md](ADVANCED.md); for architecture (services, ports, security model) see [USAGE.md](USAGE.md).

## TL;DR

`prepare-sd.sh` on your laptop → cloud-init runs `firstboot.sh` on the Pi → `firstboot.sh` calls `deploy.sh` (server) and/or `setup.sh` (client) → reboot into overlayroot + systemd-owned runtime.

## Logical flow

```text
HOST (Mac / Linux / Windows)
└─ prepare-sd.sh                      ┐ Stage repo onto SD card
   ├─ install menu (client/server/both) │ + write install.conf
   ├─ stage scripts/common modules    │ + patch user-data runcmd
   └─ patch /boot/firmware/user-data  │
                                      ┘
                          ─── flash + insert SD → power on ───

PI (boot 1 — cloud-init runs the staged hook)
└─ firstboot.sh (root)
   ├─ wait-network                            (WiFi DFS regdom fix)
   ├─ install-deps + install-docker           (Docker CE: docker-ce,
   │                                           docker-ce-cli, containerd.io,
   │                                           docker-compose-plugin)
   ├─ install-profile resolve                 (server / client / both)
   ├─ run deploy.sh   (server stack)          ┐ runs only the path
   ├─ run setup.sh    (client stack)          │ relevant to the
   ├─ run setup-zero2w.sh (native client)     ┘ install mode
   ├─ readonly/finalize phase                 ┐ ENABLE_READONLY=true:
   │   ├─ install_initramfs_lzma_hook         │  server path runs in
   │   ├─ refresh_overlayroot_modules_dep     │  firstboot finalize;
   │   └─ raspi-config nonint do_overlayfs 0  │  client/both path runs
   │                                          ┘  inside setup.sh
   ├─ /boot/firmware backup writers wired
   ├─ /var/lib/snapmulti-installer/.auto-installed marker
   └─ reboot

PI (boot 2 — systemd owns the runtime)
├─ overlayroot=tmpfs:recurse=0
├─ snapmulti-server.service     (server / both)
├─ snapclient.service           (client / both / native client)
├─ snapmulti-status.timer       (refresh /status page snapshot)
└─ snapmulti-state-backup.{path,timer}  (persist server.json + myMPD workdir)
```

## Per-mode differences

The four install modes share the same `firstboot.sh` framework; what differs is which deploy step runs and which containers / services land on the device.

| Mode | When | What runs on first boot | Final stack |
|------|------|--------------------------|-------------|
| **server** | Pi 3 / 4 / 5 wired or WiFi, no local speakers | `deploy.sh` (server-only) | 7 server containers (snapserver, mpd, mympd, metadata, shairport-sync, librespot, tidal-connect on ARM) |
| **client** | Pi 3 / 4 / 5 with attached speaker / DAC, server elsewhere on LAN | `setup.sh` (Docker stack) | 3 client containers (snapclient, audio-visualizer, fb-display) |
| **both** | Single Pi 4 / 5 acting as server + local speaker | `deploy.sh` then `setup.sh` | All 10 containers on the same host (server host networking + client bridge networking) |
| **client-native** | Pi Zero 2 W (insufficient resources for Docker) | `setup-zero2w.sh` — direct apt install of snapclient + systemd unit | 1 native service (`snapclient.service`) — no Docker |

`install-profile.sh` resolves the mode from `install.conf` (written by `prepare-sd.sh`) and from `is_pi_zero_2w` device detection. The `client-native` promotion happens transparently: an operator who chose `client` for a Pi Zero 2 W gets the native path because `client/Docker` would exceed the 512 MB RAM budget.

## Phase reference

### 1. Host: `prepare-sd.sh` / `prepare-sd.ps1`

- Shows the 3-option menu (Audio Player / Music Server / Server + Player) and the music-source menu when relevant.
- Stages the snapMULTI tree to the SD boot partition, then strips host-side junk (`__pycache__`, `._*`, `.DS_Store`).
- Writes `install.conf` with the chosen mode, music source, audio HAT.
- Bakes `server/.version` + `client/VERSION` from `git describe --tags` so the device knows which release it was flashed from.
- Patches cloud-init `user-data runcmd` so the Pi runs `/boot/firmware/snapmulti/firstboot.sh` on first boot.
- PowerShell sibling (`prepare-sd.ps1`) does the same for Windows.

### 2. Pi: cloud-init → `firstboot.sh`

- cloud-init's `runcmd` executes `/boot/firmware/snapmulti/firstboot.sh` as root.
- Progress is rendered to `/dev/tty1` (HDMI console) via `scripts/common/progress.sh` — full-screen TUI, ASCII-only, no-op when SSH-launched.
- Resilient against partial failures: every phase writes a checkpoint marker (`.done-<phase>`) in `/var/lib/snapmulti-installer/` so an interrupted firstboot resumes instead of restarting from zero on reboot. Successful completion flips `/var/lib/snapmulti-installer/.auto-installed`; a partial failure flips `.install-failed` instead — both in the same directory, NOT on the boot partition.

### 3. Pi: server path — `deploy.sh`

Server-only / both mode. Steps:

- Hardware detection → resource profile (minimal / standard / performance) writes `*_MEM_LIMIT` env vars to `.env`.
- Directory layout under `/opt/snapmulti/`.
- `docker compose pull` + `up -d` for 7 server services.
- Validates `verify_services` (containers healthy in `MPD_START_PERIOD + 120s` grace window).

### 4. Pi: client path — `setup.sh`

Client / both mode (Pi 3 / 4 / 5). Steps:

- Audio HAT detection (EEPROM → I²C scan → USB fallback).
- ALSA `/etc/asound.conf` written from the detected HAT.
- mDNS server discovery (or `SNAPSERVER_HOST` override).
- During firstboot, `docker compose up -d` starts ONLY `snapclient` with `COMPOSE_PROFILES=""`. The `framebuffer` profile (audio-visualizer + fb-display) is deferred to the post-reboot `snapclient.service`, so the install TUI on `/dev/tty3` is not stomped by fb-display drawing on `/dev/fb0`. After the reboot, `snapclient.service` reads `.env` with `COMPOSE_PROFILES=framebuffer` and the full client stack comes up.

### 5. Pi: native-client path — `setup-zero2w.sh`

Pi Zero 2 W only (RAM budget excludes Docker). Steps:

- Direct `apt install snapclient`.
- Generates a `snapclient.service` systemd unit with `ExecStartPre` for mDNS server discovery + IPv4 host pinning.
- WiFi watchdog + DSCP marking applied via boot-tune.sh (server profile-style, scaled down).

### 6. Pi: overlayroot + final reboot

- `install_initramfs_lzma_hook` ships `/etc/initramfs-tools/hooks/snapmulti-lzma` so kmod inside initramfs can decompress `overlay.ko.xz`.
- `refresh_overlayroot_modules_dep` runs `depmod -a` per kernel under `/lib/modules/*` (catches the post-`apt full-upgrade` next-boot kernel whose modules.dep would otherwise be stale).
- `raspi-config nonint do_overlayfs 0` writes the cmdline.txt token + `/etc/overlayroot.local.conf`.
- `persist_overlayroot_enabled` confirms persistence.
- `firstboot.sh` reboots. Next boot mounts `/` as overlay tmpfs (`tmpfs:recurse=0` — overlay only `/`, leave NFS/USB writable), and systemd owns the runtime from then on.

## Failure modes & recovery

`firstboot.sh` writes `/var/lib/snapmulti-installer/.install-failed` if any phase aborts (NOT on the boot partition — `/boot/firmware/` holds diagnostic + backup artefacts, not the marker). The device boots, containers come up (`snapmulti-server.service` has its own systemd `Restart=on-failure`), but overlayroot is NOT activated and the install is marked incomplete. The two common causes:

- **Large NFS / SMB library exceeds `verify_services` healthcheck window** — pre-set `MPD_START_PERIOD=3600s` in `install.conf` before flashing. See [TROUBLESHOOTING.md — Install marked failed but containers run](TROUBLESHOOTING.md#install-marked-failed-but-containers-run).
- **Docker Hub rate limit** — `docker login` on the Pi before the next firstboot retry.

`/status` HTTP page on the server (`http://<server>.local:8083/status`) and the diagnostic bundle (`/usr/local/bin/save-diagnostics`) are the operator's two debugging surfaces. See [TROUBLESHOOTING.md](TROUBLESHOOTING.md) for the full failure-mode table.

## See also

- [INSTALL.md](INSTALL.md) — beginner install walk-through.
- [ADVANCED.md](ADVANCED.md) — multi-room, NFS/SMB library, custom `.env`, manual deploy, read-only filesystem, update strategy.
- [USAGE.md](USAGE.md) — architecture reference (services, ports, security, mDNS).
- [TROUBLESHOOTING.md](TROUBLESHOOTING.md) — failure modes + diagnostic bundle recovery.
- [HARDWARE.md](HARDWARE.md) — supported boards + HATs.
