🇬🇧 **English** | 🇮🇹 [Italiano](ADVANCED.it.md)

# Advanced Guide

Operational reference and customisation for users who already have a running snapMULTI. For first-time install see [INSTALL.md](INSTALL.md); for the technical pipeline that runs between flash and reboot see [INSTALL-FLOW.md](INSTALL-FLOW.md); for failures see [TROUBLESHOOTING.md](TROUBLESHOOTING.md).

Contents:

- [Multi-room — adding speakers](#multi-room--adding-speakers)
- [Music library on the network (NFS / SMB)](#music-library-on-the-network)
- [Custom config — `.env` files](#custom-config--env-files)
  - [Changing settings on a read-only Pi](#changing-settings-on-a-read-only-pi)
  - [Disabling Tidal Connect](#disabling-tidal-connect)
- [Read-only filesystem](#read-only-filesystem)
- [Deployment without `prepare-sd`](#deployment-without-prepare-sd)
- [MPD from the command line](#mpd-from-the-command-line)
- [Switch source via JSON-RPC](#switch-source-via-json-rpc)
- [Systemd units](#systemd-units)
- [Update strategy](#update-strategy)
- [Resource profiles](#resource-profiles)
- [Firewall rules](#firewall-rules)
- [Network QoS](#network-qos)

## Multi-room — adding speakers

For each additional speaker:

1. Flash a new SD card with Raspberry Pi Imager
   - Set a **unique hostname** (e.g. `kitchen`, `bedroom`, `garden`)
   - Same user/password as your server is convenient but not required
2. Re-insert → run `prepare-sd.sh` → choose **1) Audio Player**
3. Boot → the speaker Pi auto-discovers the server via mDNS

The new speaker appears in Snapweb (`http://<server>.local:1780`) within ~30 seconds of booting. Group it with existing rooms via drag-and-drop in the web UI.

> **Linux box as speaker:** any Linux machine on the LAN can join as a snapclient — `sudo apt install snapclient`, then `systemctl edit snapclient` and set `--host=<server>.local`. No reflash needed.

## Music library on the network

If your library lives on a NAS (Synology, QNAP, generic Linux server, Windows share), `prepare-sd.sh` Menu 3 asks for the share path during install. Pick the protocol that matches your NAS:

| Protocol | When | Notes |
|----------|------|-------|
| NFS | Linux / Synology / QNAP NAS, allow-list by IP | `prepare-sd.sh` writes a systemd `.mount`/`.automount` pair; no password |
| SMB / CIFS | Windows share, Synology / QNAP with username + password | `prepare-sd.sh` writes the credentials temporarily into `install.conf` on the FAT32 boot partition. On first boot, `firstboot.sh` copies them to `/etc/snapmulti-smb-credentials` with root-only permissions and then removes them from `install.conf` |
| USB | Drive plugged into the Pi | The first USB partition with a filesystem is auto-detected on first boot (`mount-music.sh` scans `/dev/sd?1`/`/dev/sd?`) and mounted at `/media/usb-music` via a systemd automount keyed on its UUID — no menu selection |
| Local | A folder on the Pi itself | `MUSIC_PATH` in `/opt/snapmulti/.env` (default `/media/music`; MPD sees it as `/music`). Used by the "I'll set it up later" choice — copy files there, or point `MUSIC_PATH` at your own disk ([how to change settings](#changing-settings-on-a-read-only-pi)) |

Path naming: NAS shares with **spaces** are rejected at install time (Synology defaults `Music Share` → rename on the NAS to `Music_Share`). See [TROUBLESHOOTING.md](TROUBLESHOOTING.md) if the mount silently fails post-install.

> **MPD rescan on big libraries.** A first scan of a 10 k+ song library over NFS can take hours. Run `scripts/backup-from-sd.sh` on the old SD card before reflashing — it extracts `mpd.db` so the next install loads the cached database in seconds instead of rescanning (see [Update strategy](#update-strategy)).

### `MPD_START_PERIOD` — large libraries and the install healthcheck window <a id="mpd_start_period"></a>

The first-boot install waits `max(MPD_START_PERIOD, 180s) + 120s` for MPD to bind port 6600. `deploy.sh` sets `MPD_START_PERIOD` from the music source only (300 s for NFS / SMB, 30 s otherwise) and ignores any value in `install.conf`. A first cold scan of a very large network library (> ~10 k tracks) can overrun that window: the install is then marked failed and read-only mode is never enabled, even though the containers come up later on their own. The symptom, the checks and the recovery (raise `MPD_START_PERIOD` in `.env`, clear the failure marker, rerun `firstboot.sh`) are in [TROUBLESHOOTING.md — Install marked failed but containers run](TROUBLESHOOTING.md#install-marked-failed-but-containers-run).

## Custom config — `.env` files

| Path | What it controls |
|------|------------------|
| `/opt/snapmulti/.env` | Server: hostname, music source, container resource limits, optional AirPlay / Spotify / Tidal name overrides |
| `/opt/snapclient/.env` | Client: sound card override, latency, display profile, server hostname (for static-IP fallback) |

> **Edits on a read-only Pi are lost at the next reboot.** Read-only mode is on by default after a `prepare-sd` install: the whole root filesystem, `/opt` included, runs from RAM. Only the myMPD workdir and snapserver's `server.json` are backed up to the boot partition and restored at boot ([details](#read-only-filesystem)) — `.env` is not. Use the procedure below for every change you want to keep. A reflash also writes a fresh `.env`, so custom values must be re-applied after each reflash.

### Changing settings on a read-only Pi

1. Turn read-only mode off and reboot:

   ```bash
   sudo ro-mode disable && sudo reboot
   ```

2. Log back in and make the change:

   ```bash
   sudo nano /opt/snapmulti/.env        # Audio Player: /opt/snapclient/.env
   ```

3. Apply it. Use `up -d`, not `restart` — `restart` does not re-read `.env`:

   ```bash
   cd /opt/snapmulti && sudo docker compose up -d     # Audio Player: cd /opt/snapclient
   ```

4. Turn read-only mode back on and reboot:

   ```bash
   sudo ro-mode enable && sudo reboot
   ```

`ro-mode status` shows the current state. If you turned read-only mode off in the `prepare-sd` advanced menu, skip steps 1 and 4.

Per-source device names, for example (step 2):

```bash
AIRPLAY_NAME="Living Room AirPlay"
SPOTIFY_NAME="Living Room Spotify"
TIDAL_NAME="Living Room Tidal"
```

Full inline reference: [`config/snapserver.conf`](../config/snapserver.conf) is the authoritative parameter schema for snapserver itself.

### Disabling Tidal Connect

Tidal Connect is enabled by default on Raspberry Pi (ARM) installs. It runs a proprietary, unmaintained upstream binary — see the [security note](USAGE.md#tidal-connect-security-note). To turn it off, follow [Changing settings on a read-only Pi](#changing-settings-on-a-read-only-pi) and in steps 2–3:

1. In `/opt/snapmulti/.env`, set `TIDAL_ENABLED=false` and remove `tidal` from the `COMPOSE_PROFILES=` line (leave it empty if `tidal` was the only entry). Removing it from `COMPOSE_PROFILES` alone is not enough: `deploy.sh` puts it back the next time it runs unless `TIDAL_ENABLED=false` is set.
2. Stop the running container and apply:

   ```bash
   cd /opt/snapmulti
   sudo docker compose rm -sf tidal-connect
   sudo docker compose up -d
   ```

A reflash turns Tidal Connect back on; repeat these steps afterwards.

## Read-only filesystem

After install completes, the rootfs is mounted read-only via overlayroot + fuse-overlayfs. Edits to `/etc`, `/opt`, etc. survive until reboot, then get wiped. Toggle for maintenance with the `ro-mode` helper (installed at `/usr/local/bin/ro-mode` on every device):

```bash
sudo ro-mode disable && sudo reboot   # writable from the next boot
# make changes (.env edits, apt install, config files)
sudo ro-mode enable && sudo reboot    # read-only again
ro-mode status                        # check the current state
```

Step-by-step version for `.env` edits: [Changing settings on a read-only Pi](#changing-settings-on-a-read-only-pi).

> **Exceptions — state that survives overlayroot wipes:** `snapmulti-state-backup.path` watches `myMPD state changes` (`/opt/snapmulti/mympd/workdir/state` — the change-frequent subdir myMPD writes to as the user touches playlists / settings / scripts). When the path unit triggers, the backup script snapshots the WHOLE myMPD workdir to `/boot/firmware/snapmulti-backup/` — state + config + smartpls + scripts + pics — not just the `state/` subdir it was triggered by, so user-customised smart playlists / themes / scripts survive a reflash. `snapmulti-state-backup.timer` is the safety net: it runs every 5 min and captures snapserver `server.json` (event-driven on that file is not viable — snapserver rewrites it every ~3 s to refresh client `lastSeen` heartbeats). `backup-snapmulti-state.sh` short-circuits on canonical equality (sort keys + strip `lastSeen` + sha256) so no-op ticks cost zero FAT32 writes. `snapmulti-backup.timer` separately backs up MPD `mpd.db` on boot/daily cadence. On every boot, `restore-snapmulti-state` (wired as `ExecStartPre` on `snapmulti-server.service`) copies the state backup back into `/opt/snapmulti/` before containers start. v0.7.9's `snapmulti-data-persistence.service` bind-mount approach was removed in v0.7.9.1 (see #527) — it was a no-op on tmpfs-mode overlayroot.

`/boot/firmware/cmdline.txt` is managed by `scripts/common/cmdline-manager.sh` (it adds and removes `overlayroot=tmpfs`, the memory-cgroup flags and other tokens). Don't rewrite or reorder the file by hand. To add a kernel flag, use the same helper, as shown for [`ipv6.disable=1`](#ipv6-enabled-by-default).

## Deployment without `prepare-sd`

Used to install on an existing Linux host (not via flash). Requires Docker + Docker Compose + git.

```bash
git clone https://github.com/lollonet/snapMULTI.git
cd snapMULTI
sudo bash scripts/deploy.sh        # interactive: detects hardware, writes .env, pulls images
```

For full manual control:

```bash
cp .env.example .env
nano .env                          # at minimum: PUID/PGID, MUSIC_PATH, MUSIC_SOURCE
sudo docker compose up -d
```

Reflash with the latest release to pick up the release manifest and any image-set change. Script-only releases reuse the existing Docker image set; container-changing releases publish a new pinned image set through CI.

## MPD from the command line

```bash
sudo apt install mpc
mpc -h <server> play | pause | next | volume 50 | status
mpc -h <server> add "Artist/Album"
mpc -h <server> update                # rescan library — see notes above for NFS
```

## Switch source via JSON-RPC

```bash
# list streams
curl -s http://<server>:1780/jsonrpc -d \
  '{"id":1,"jsonrpc":"2.0","method":"Server.GetStatus"}' | jq '.result.server.streams[].id'

# switch a group to Spotify
curl -s http://<server>:1780/jsonrpc -d \
  '{"id":1,"jsonrpc":"2.0","method":"Group.SetStream","params":{"id":"<GROUP_ID>","stream_id":"Spotify"}}'
```

Full schema: [Snapcast JSON-RPC v2.0.0](https://github.com/badaix/snapcast/blob/master/doc/json_rpc_api/v2_0_0.md).

## Systemd units

After install, systemd owns the container lifecycle (ADR-005). Docker `restart: unless-stopped` handles crashes, systemd handles boot. The authoritative unit inventory (server / client / all) lives in [USAGE.md](USAGE.md#systemd-units) — inspect any of them with `systemctl cat <unit>`. Unit files are installed by `firstboot.sh`.

## Update strategy

snapMULTI updates by reflashing the SD card ([DEC-003](decisions/DEC-003-reflash-only-updates.md)) — the read-only root makes in-place patching impractical. To see whether a newer release exists, open the `/status` page: it shows `Update available: <current> -> <latest> (reflash to apply)` when there is one (the same line appears in `device-smoke.sh` output).

### Updating by reflash

Do the steps in this order — step 1 must happen **before** Imager overwrites the old card.

1. **Save the server's state from the old SD** (Music Server / Server + Player only; an Audio Player has nothing to save). Shut the Pi down (`sudo poweroff`), put its SD card in your laptop, download and extract the new release, and from that folder run:

   ```bash
   ./scripts/backup-from-sd.sh                    # auto-detects the SD
   ./scripts/backup-from-sd.sh /Volumes/bootfs    # or give the boot partition path
   ```

   It copies three things from the SD's `snapmulti-backup/` folder into the release folder: the MPD database (`mpd.db`, so a big library is not rescanned), the myMPD workdir (playlists, settings, smart playlists) and snapserver's `server.json` (speaker groups, names, volumes). `prepare-sd` puts them on the new card in step 3. `mpd.db` is reused only for NFS / SMB libraries; USB and local libraries are rescanned.

   **Windows** (there is no PowerShell version of this script): open the SD's boot partition in File Explorer and copy from its `snapmulti-backup\` folder into the extracted release folder, keeping the same sub-paths — `mpd\data\mpd.db`, the whole `mympd\workdir\` folder, and `data\server.json` (whichever exist).

2. **Flash** the card with Raspberry Pi Imager and enter the Imager settings again — hostname, username / password, WiFi, SSH. Keep the same hostname so speakers and apps find the device under the same name.
3. **Run `prepare-sd`** from the new release folder and answer its menus again (role, audio output, music source and NAS details, advanced options). Nothing else carries over from the old install.
4. **Boot** and wait the usual ~15-20 min on a Pi 4/5.
5. **Re-apply any custom `.env` values** (device names, Tidal opt-out, boot-tone opt-out, …) — the new install writes a fresh `.env`. See [Changing settings on a read-only Pi](#changing-settings-on-a-read-only-pi).
6. **Check the result**: `/status` all green, or run the smoke test on the device — `sudo bash /opt/snapmulti/scripts/device-smoke.sh --server` (`--both` for Server + Player); on an Audio Player: `sudo bash /opt/snapclient/scripts/device-smoke.sh --client`. It's the same release gate (ADR-005) that `fleet-smoke.sh` runs across multiple devices. Full description in [TROUBLESHOOTING.md — First check](TROUBLESHOOTING.md#first-check--run-the-smoke-test).

### In-place (advanced, unsupported)

With read-only mode off ([how](#read-only-filesystem)): `cd /opt/snapmulti && sudo docker compose pull && sudo docker compose up -d`. This only re-pulls the image tag already pinned in `.env` (`IMAGE_TAG`); it does not update scripts, config files or systemd units. Config drift between versions is your problem to resolve.

## Release strategy & image-set pinning

> Architectural rationale: [ADR-006](adr/ADR-006.release-identity-script-only-patches.md).

snapMULTI separates two version concepts so a script-only release (CHANGELOG, docs, installer fixes) does not force a Docker image rebuild + repush:

- **`SNAPMULTI_RELEASE`** — the git tag of the release (e.g. `v0.8.3`). What `gh release view` shows.
- **`SNAPMULTI_IMAGE_SET`** — the Docker image tag the release pins to (e.g. `0.7.7`). What `docker compose pull` fetches.

Most releases bump both. A script-only release bumps `SNAPMULTI_RELEASE` and keeps `SNAPMULTI_IMAGE_SET` at the last published value. The source of truth is `release-manifest.json` at the repo root, staged onto the SD by `prepare-sd.sh`.

### Precedence chain

Since v0.7.8.10 (SSOT consolidation), `install.conf` no longer carries release identity — release-manifest.json on the SD is the only source. `IMAGE_TAG` stays in `install.conf` as the one legitimate operator override.

- **`SNAPMULTI_RELEASE`** = `manifest snapmulti_release` > `""`
- **`SNAPMULTI_IMAGE_SET`** = `manifest image_set` > `""`
- **`IMAGE_TAG`** (Docker tag actually pulled) = `install.conf IMAGE_TAG` (operator override — `dev`, a specific tag) > `manifest image_set` > `latest`

Implemented once in `scripts/common/release-manifest.sh::derive_image_tag()` and consumed by `firstboot.sh`, `deploy.sh`, and the client's `setup.sh`.

### Compatibility matrix

| install.conf | manifest | Resulting `IMAGE_TAG` |
|--------------|----------|-----------------------|
| `IMAGE_TAG=0.7.4` only | — | `0.7.4` (legacy SD card from v0.7.4) |
| `IMAGE_TAG=latest` only | — | `latest` (legacy default) |
| empty | absent | `latest` |
| empty | `image_set=0.7.7` | `0.7.7` |
| `IMAGE_TAG=dev` | `image_set=0.7.7` | `dev` (operator override wins) |

Reproduced in `tests/test_firstboot_image_tag_derivation.sh`.

### Cutting a script-only release

1. Edit `release-manifest.json`:
   - Bump `snapmulti_release` to the new tag (e.g. `v0.7.8`)
   - Keep `image_set` at the last published value (e.g. `0.7.7`)
   - Set `requires_image_rebuild` to `false`
2. Update `CHANGELOG.md` `[Unreleased]` → new version header.
3. Open a PR, pass CI and the [real-device release gate](adr/ADR-005.reflash-systemd-robustness.md#release-gate), merge, then tag the verified commit (`git tag v0.7.8 && git push origin v0.7.8`).
4. The `build-push.yml` gate reads the manifest, sees `requires_image_rebuild=false`, verifies all 5 production images exist on Docker Hub at `:0.7.7`, and **skips the build matrix**. After the gate succeeds, publish the GitHub Release for that tag with release notes; this workflow does not create it automatically. Users reflash from the release to receive the updated scripts while reusing the same image set.

### Cutting a container-changing release

1. Edit `release-manifest.json`:
   - Bump `snapmulti_release` to the new tag (e.g. `v0.8.0`)
   - Bump `image_set` to match (e.g. `0.8.0`)
   - Set `requires_image_rebuild` to `true`
2. Update `CHANGELOG.md`, open PR, merge, tag.
3. The gate sees `requires_image_rebuild=true` and runs the full matrix, publishing `:0.8.0` images on Docker Hub.

### Emergency override — `force_rebuild`

If the published image set on Docker Hub is missing or corrupted (security CVE in a base image, accidental tag deletion, GitHub Container Registry incident), trigger `build-push.yml` manually with `force_rebuild=true`:

```text
GitHub → Actions → Build and Push Images → Run workflow
  force_rebuild: ☑ true
```

The gate bypasses both `requires_image_rebuild=false` and the Docker Hub existence check; the matrix runs and republishes whatever `image_set` the manifest names (NOT the just-cut tag). Dispatch it from the release tag to rebuild exactly the released code; a dispatch from a branch publishes `<image_set>` plus `:manual`, never `:latest`.

### Inspecting the live release identity

After a deploy / reflash:

- Smoke test info line: `device-smoke.sh` → `System` section → `Release v0.8.3 (images 0.7.7)`
- Diagnostic bundle: `scripts/diagnostic.sh` produces `meta.txt` with `snapmulti_release=...` and `snapmulti_image_set=...`; the bundle also includes the scrubbed `release-manifest.json` from the boot partition.
- Server `.env`: `grep ^SNAPMULTI_ /opt/snapmulti/.env`
- Client `.env`: `grep ^SNAPMULTI_ /opt/snapclient/.env`

## Resource profiles

`deploy.sh` (server) and `setup.sh` (client) auto-detect hardware and apply one of three profiles — **minimal**, **standard**, or **performance**. Limits can be overridden in `.env` ([how](#changing-settings-on-a-read-only-pi)).

### Profile selection

The profile follows installed RAM, not the board name:

| Profile | Typical hardware |
|---------|------------------|
| minimal | Pi 3, Pi Zero 2 W, Pi 4 / Pi 5 1 GB |
| standard | Pi 4 / Pi 5 2 GB |
| performance | Pi 4 / Pi 5 4 GB and up |

Other hosts: under 2 GB minimal; performance from 8 GB on the server, 4 GB on a player; standard in between. Re-running `deploy.sh` rewrites the profile block in `.env` when the values differ (each change is logged): an edit inside that block is reset, an override placed after it wins.

### Server memory limits

| Service | minimal | standard | performance |
|---------|---------|----------|-------------|
| snapserver | 128M | 192M | 256M |
| shairport-sync | 48M | 64M | 96M |
| librespot | 96M | 256M | 256M |
| mpd | 128M | 384M | 384M |
| mympd | 32M | 64M | 256M |
| metadata | 96M | 128M | 128M |
| tidal-connect | 64M | 96M | 128M |
| **Total** | **592M** | **1,184M** | **1,504M** |

### Client memory limits

| Service | minimal | standard | performance |
|---------|---------|----------|-------------|
| snapclient | 64M | 64M | 96M |
| audio-visualizer | 128M | 128M | 192M |
| fb-display | 192M | 256M | 384M |
| **Total** | **384M** | **448M** | **672M** |

`fb-display` footprint scales with resolution — 4K is noticeably heavier than 1080p. Headless clients (no display) run only `snapclient` and stay lightweight.

### Hardware compatibility matrix

Assumes ~200 MB OS + Docker overhead: % RAM = limits ÷ (RAM − 200 MB). Percentages represent *limit ceilings*, not actual usage.

**Server-only** (all services including Tidal on ARM):

| Hardware | RAM | Profile | Limits | % RAM | Status |
|----------|-----|---------|--------|-------|--------|
| Pi Zero 2 W | 512M | minimal | 592M | 190% | **Not supported** |
| Pi 3 1 GB | 1024M | minimal | 592M | 72% | Tight — works, no headroom for spikes |
| Pi 4 / Pi 5 2 GB | 2048M | standard | 1,184M | 64% | OK |
| Pi 4 / Pi 5 4 GB | 4096M | performance | 1,504M | 39% | OK |
| Pi 4 / Pi 5 8 GB | 8192M | performance | 1,504M | 19% | OK |

**Client with display:**

| Hardware | RAM | Profile | Limits | % RAM | Status |
|----------|-----|---------|--------|-------|--------|
| Pi Zero 2 W | 512M | minimal | 384M | 123% | **Not supported** |
| Pi 3 1 GB | 1024M | minimal | 384M | 47% | OK |
| Pi 4 / Pi 5 2 GB | 2048M | standard | 448M | 24% | OK |
| Pi 4 / Pi 5 4 GB+ | 4096M+ | performance | 672M | ≤ 17% | OK |

**Client headless** (snapclient only):

| Hardware | RAM | Profile | Limits | Status |
|----------|-----|---------|--------|--------|
| Pi Zero 2 W | 512M | minimal | 64M | OK |
| Pi 3 1 GB | 1024M | minimal | 64M | OK |
| Any 2 GB+ | 2 GB+ | standard+ | 64–96M | OK |

**Both mode** (server + client with display on same Pi):

| Hardware | RAM | Profile | Server | Client | Total | % RAM | Status |
|----------|-----|---------|--------|--------|-------|-------|--------|
| Pi Zero 2 W | 512M | minimal | 592M | 384M | 976M | 313% | **Not supported** |
| Pi 3 1 GB | 1024M | minimal | 592M | 384M | 976M | 118% | **Not supported** |
| Pi 4 / Pi 5 2 GB | 2048M | standard | 1,184M | 448M | 1,632M | 88% | Tight — works, limited headroom |
| Pi 4 / Pi 5 4 GB+ | 4096M+ | performance | 1,504M | 672M | 2,176M | ≤ 56% | OK |

**Both mode** (server + headless client on same Pi):

| Hardware | RAM | Profile | Server | Client | Total | % RAM | Status |
|----------|-----|---------|--------|--------|-------|-------|--------|
| Pi Zero 2 W | 512M | minimal | 592M | 64M | 656M | 210% | **Not supported** |
| Pi 3 1 GB | 1024M | minimal | 592M | 64M | 656M | 80% | Tight — works, limited headroom |
| Pi 4 / Pi 5 2 GB | 2048M | standard | 1,184M | 64M | 1,248M | 68% | OK |
| Pi 4 / Pi 5 4 GB+ | 4096M+ | performance | 1,504M | 96M | 1,600M | ≤ 41% | OK |

> Services rarely hit their limits simultaneously — limits exist to prevent runaway processes from starving the host, so a ceiling above ~80% of RAM is a worst case, not expected usage.

## Firewall rules

If the host runs `ufw` or an equivalent, open these ports on the **server** side (each port's direction and purpose is defined in [USAGE.md — Ports](USAGE.md#ports)):

```bash
# Snapcast core
sudo ufw allow 1704/tcp   # Audio streaming
sudo ufw allow 1705/tcp   # JSON-RPC control
sudo ufw allow 1780/tcp   # HTTP API + Snapweb UI

# Audio sources
sudo ufw allow 4953/tcp   # TCP audio input (ffmpeg / Android streaming)
sudo ufw allow 5000/tcp   # AirPlay (shairport-sync RTSP)
sudo ufw allow 5858/tcp   # AirPlay cover art (meta_shairport in snapserver)
sudo ufw allow 2019/tcp   # Tidal Connect discovery (ARM only)
# Spotify Connect uses a random TCP port for zeroconf — allow the ephemeral
# range or use connection tracking:
# sudo ufw allow proto tcp from 192.168.0.0/16 to any port 30000:65535

# Music library
sudo ufw allow 6600/tcp   # MPD protocol
sudo ufw allow 8000/tcp   # MPD HTTP stream
sudo ufw allow 8180/tcp   # myMPD web UI

# Metadata
sudo ufw allow 8082/tcp   # Metadata service (WebSocket)
sudo ufw allow 8083/tcp   # Metadata service (HTTP / cover art)

# Discovery
sudo ufw allow 5353/udp   # mDNS (Avahi / Bonjour)
```

Full port table (with direction and purpose): [USAGE.md — Ports](USAGE.md#ports).

## IPv6 enabled by default

snapMULTI enables IPv6 at the kernel level by default (ADR-008 supersedes the earlier ADR-007 kernel-disable). The original dual-stack mDNS races are closed by software defenses (Avahi `use-ipv6=no`, snapclient IPv4 SRV pin via `discover-server.sh`, fb-display IPv4 zeroconf filter, `boot-tune.sh` single-publish on dual-iface hosts), so the kernel kill-switch was redundant. Tidal Connect's proprietary binary requires `socket(AF_INET6)` for its WebSocket listen — leaving IPv6 on means it works out-of-box.

Operators with a hard reason to disable IPv6 at the kernel level (legacy network, broken router advertisements, etc.) can opt back into the ADR-007 behaviour by setting `DISABLE_IPV6=true` before preparing the SD card:

```bash
DISABLE_IPV6=true ./scripts/prepare-sd.sh /Volumes/bootfs
```

```powershell
$env:DISABLE_IPV6='true'; .\scripts\prepare-sd.ps1 -Boot E:\
```

To disable IPv6 on an already-installed device without reflashing, add the token with the same helper `prepare-sd` uses (`cmdline.txt` must stay a single line; the helper takes care of that). The boot partition is outside the read-only overlay, so no `ro-mode` toggle is needed:

```bash
sudo mount -o remount,rw /boot/firmware
sudo bash -c '. /opt/snapmulti/scripts/common/cmdline-manager.sh && cmdline_add_token ipv6.disable=1'
# Audio Player: use /opt/snapclient/scripts/common/cmdline-manager.sh
sudo mount -o remount,ro /boot/firmware
sudo reboot
```

To undo, run the same commands with `cmdline_remove_token ipv6.disable=1`. See ADR-008 for the full rationale (and ADR-007 for the historical context it supersedes).

## Network QoS

On a server install, `deploy.sh` gives Snapcast audio priority over bulk traffic on the default-route interface, when the kernel has the `sch_cake` module:

```bash
# What deploy.sh runs (re-applied on every interface up by
# /etc/NetworkManager/dispatcher.d/50-cake-qos)
tc qdisc replace dev <iface> root cake diffserv4
iptables -t mangle -A OUTPUT -p tcp --sport 1704 -j DSCP --set-dscp-class EF
iptables -t mangle -A OUTPUT -p tcp --sport 1705 -j DSCP --set-dscp-class EF
```

CAKE runs without a bandwidth limit; `diffserv4` puts the EF-marked Snapcast streaming (1704) and control (1705) packets in its highest-priority tin. There is no `.env` switch to turn it off. On a quiet home LAN the effect is undetectable; under heavy parallel transfers it's the difference between glitch-free audio and dropouts. `device-smoke.sh` checks both the CAKE qdisc and the DSCP marking in its QoS section.

## 4K @ 60Hz HDMI on Pi 4 client displays

Pi 4 ships with a conservative GPU clock that maxes out at 4K @ 30Hz. When the client Pi drives a 4K-capable TV/monitor, the kernel logs:

```
vc4-drm gpu: [drm] The core clock cannot reach frequencies high enough to support 4k @ 60Hz.
vc4-drm gpu: [drm] Please change your config.txt file to add hdmi_enable_4kp60.
```

snapMULTI's `fb-display` container works at any HDMI mode — frame rate doesn't affect rendered content. But the 4K TV will show a degraded 1080p @ 60Hz or 4K @ 30Hz signal until the GPU clock boost is enabled.

### Fix (no overlayroot dance — `/boot/firmware` is FAT32, outside overlayroot)

```bash
ssh <client-host>
sudo mount -o remount,rw /boot/firmware
sudo sh -c 'echo "hdmi_enable_4kp60=1" >> /boot/firmware/config.txt'
sudo mount -o remount,ro /boot/firmware
sudo reboot
```

After reboot:
- `vc4-drm` warnings gone from `journalctl -p warning`
- Framebuffer reports `3840x2160`
- SoC temperature rises ~1-2 °C steady-state (within Pi 4 thermal envelope)

Validated on snapdigi (Pi 4 2GB + LG 50" 4K TV) 2026-05-21.

## Split server+client topology — `EXTERNAL_HOST`

When the snapMULTI server runs on one host and clients run on different hosts (e.g. server on a NAS, players in each room), `metadata-service` must advertise an externally-reachable address so clients can fetch cover artwork over HTTP `:8083`.

Since v0.7.8.1 the service auto-detects the host's LAN IP via the kernel routing table — no configuration needed for the vast majority of installs. The startup log shows the resolved value:

```
INFO  External host: 192.168.1.10
```

Override only when auto-detection picks the wrong interface (multi-homed hosts, VPN routes, container weirdness). Set `EXTERNAL_HOST=<lan-ip>` in `/opt/snapmulti/.env` and restart `metadata`. A startup warning fires only if both auto-detection AND your explicit value resolve to loopback — that's the case where remote clients genuinely can't reach the artwork URLs.
