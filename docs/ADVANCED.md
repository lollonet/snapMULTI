🇬🇧 **English** | 🇮🇹 [Italiano](ADVANCED.it.md)

# Advanced Guide

Operational reference and customisation for users who already have a running snapMULTI. For first-time install see [INSTALL.md](INSTALL.md); for failures see [TROUBLESHOOTING.md](TROUBLESHOOTING.md).

Contents:

- [Multi-room — adding speakers](#multi-room--adding-speakers)
- [Music library on the network (NFS / SMB)](#music-library-on-the-network)
- [Custom config — `.env` files](#custom-config--env-files)
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

If your library lives on a NAS (Synology, QNAP, generic Linux server, Windows share), `prepare-sd.sh` Menu 2 asks for the share path during install. Pick the protocol that matches your NAS:

| Protocol | When | Notes |
|----------|------|-------|
| NFS | Linux / Synology / QNAP NAS, allow-list by IP | `prepare-sd.sh` writes a systemd `.mount`/`.automount` pair; no password |
| SMB / CIFS | Windows share, Synology / QNAP with username + password | `prepare-sd.sh` writes the credentials temporarily into `install.conf` on the FAT32 boot partition. On first boot, `firstboot.sh` copies them to `/etc/snapmulti-smb-credentials` with root-only permissions and then removes them from `install.conf` |
| USB | Drive plugged into the Pi | Auto-mounted by `udisks2`; pick the partition UUID in the menu |
| Local | Files copied into `/audio` on the Pi | Default for first-time users |

Path naming: NAS shares with **spaces** are rejected at install time (Synology defaults `Music Share` → rename on the NAS to `Music_Share`). See [TROUBLESHOOTING.md](TROUBLESHOOTING.md) if the mount silently fails post-install.

> **MPD rescan on big libraries.** A first scan of a 10 k+ song library over NFS can take hours of D-state. Use `scripts/backup-from-sd.sh` on the old SD card before reflashing — it extracts `mpd.db` so MPD does fast incremental scans across reflashes.

## Custom config — `.env` files

| Path | What it controls |
|------|------------------|
| `/opt/snapmulti/.env` | Server: hostname, music source, container resource limits, optional Tidal name / Spotify name overrides |
| `/opt/snapclient/.env` | Client: sound card override, latency, display profile, server hostname (for static-IP fallback) |

To reload after editing:

```bash
sudo nano /opt/snapmulti/.env
cd /opt/snapmulti && sudo docker compose up -d   # NOT restart — restart doesn't reload .env
```

Customise per-source device names without editing config files:

```bash
SPOTIFY_NAME="Living Room Spotify"
TIDAL_NAME="Living Room Tidal"
```

Full inline reference: [`config/snapserver.conf`](../config/snapserver.conf) is the authoritative parameter schema for snapserver itself.

## Read-only filesystem

After install completes, the rootfs is mounted read-only via overlayroot + fuse-overlayfs. Edits to `/etc`, `/opt`, etc. survive until reboot, then get wiped. Toggle for maintenance:

```bash
sudo /opt/snapmulti/scripts/ro-mode.sh disable   # then reboot
# make changes (apt install, edit configs outside /opt/snapmulti and /opt/snapclient)
sudo /opt/snapmulti/scripts/ro-mode.sh enable    # then reboot
```

`/boot/firmware/cmdline.txt` is owned by `scripts/common/cmdline-manager.sh` — don't hand-edit it. See ADR-003 for the rationale.

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

Tag push (`v*`) triggers CI multi-arch builds (amd64 + arm64 native runners) → Docker Hub `:latest`. Reflash to pick up the new images.

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

After install, systemd owns container lifecycle (ADR-005). Docker `restart: unless-stopped` handles crashes, systemd handles boot.

- Server: `snapmulti-server.service`, `snapmulti-status.timer`, `snapmulti-backup.timer`
- Client: `snapclient.service`, `snapclient-discover.timer`, `snapclient-display.service` (HDMI clients only)
- All: `snapmulti-boot-tune.service` (CPU governor, USB autosuspend, WiFi powersave)

Inspect with `systemctl cat <unit>`. Unit files are installed by `firstboot.sh`.

## Update strategy

- **Primary** (recommended): reflash the SD with the latest release. Backup MPD's library index first:

  ```bash
  ./scripts/backup-from-sd.sh         # extracts mpd.db from old SD before flashing
  ```

- **In-place** (advanced, unsupported): `cd /opt/snapmulti && sudo docker compose pull && sudo docker compose up -d`. Config drift between versions is your problem to resolve.

Reflash-first is the project default (DEC-003). All config auto-detects on first boot — same hostname / same music source / same HAT.

After every reflash or in-place update, run the smoke test on the device to confirm the platform came back healthy: `sudo bash /opt/snapmulti/scripts/device-smoke.sh --server` (or `--client` / `--both`). It's the same release gate (ADR-005) that `fleet-smoke.sh` runs across multiple devices. Full description in [TROUBLESHOOTING.md — First check](TROUBLESHOOTING.md#first-check--run-the-smoke-test).

## Resource profiles

`deploy.sh` (server) and `setup.sh` (client) auto-detect hardware and apply one of three profiles — **minimal**, **standard**, or **performance**. Limits can be overridden in `.env`.

### Profile selection

| Hardware | RAM | Profile |
|----------|-----|---------|
| Pi Zero 2 W, Pi 3 | < 2 GB | minimal |
| Pi 4 2 GB | 2–4 GB | standard |
| Pi 4 4 GB+, Pi 5, x86_64 | 4 GB+ | performance |

### Server memory limits

| Service | minimal | standard | performance |
|---------|---------|----------|-------------|
| snapserver | 128M | 192M | 256M |
| shairport-sync | 48M | 64M | 96M |
| librespot | 96M | 256M | 256M |
| mpd | 128M | 256M | 384M |
| mympd | 32M | 64M | 128M |
| metadata | 96M | 128M | 128M |
| tidal-connect | 64M | 96M | 128M |
| **Total** | **592M** | **1,056M** | **1,376M** |

### Client memory limits

| Service | minimal | standard | performance |
|---------|---------|----------|-------------|
| snapclient | 64M | 64M | 96M |
| audio-visualizer | 96M | 128M | 192M |
| fb-display | 192M | 256M | 384M |
| **Total** | **352M** | **448M** | **672M** |

`fb-display` footprint scales with resolution — 4K is noticeably heavier than 1080p. Headless clients (no display) run only `snapclient` and stay lightweight.

### Hardware compatibility matrix

Assumes ~200 MB OS + Docker overhead. Percentages represent *limit ceilings*, not actual usage.

**Server-only** (all services including Tidal on ARM):

| Hardware | RAM | Profile | Limits | % RAM | Status |
|----------|-----|---------|--------|-------|--------|
| Pi Zero 2 W | 512M | minimal | 592M | 190% | **Not supported** |
| Pi 3 1 GB | 1024M | minimal | 592M | 72% | Tight — works, no headroom for spikes |
| Pi 4 2 GB | 2048M | standard | 1,056M | 57% | OK |
| Pi 4 4 GB+ | 4096M | performance | 1,376M | 35% | OK |
| Pi 5 | 4–8 GB | performance | 1,376M | 17–35% | OK |

**Client with display:**

| Hardware | RAM | Profile | Limits | % RAM | Status |
|----------|-----|---------|--------|-------|--------|
| Pi Zero 2 W | 512M | minimal | 352M | 113% | **Not supported** |
| Pi 3 1 GB | 1024M | minimal | 352M | 43% | OK |
| Pi 4 2 GB | 2048M | standard | 448M | 24% | OK |
| Pi 4 4 GB+ | 4096M | performance | 672M | 17% | OK |

**Client headless** (snapclient only):

| Hardware | RAM | Profile | Limits | Status |
|----------|-----|---------|--------|--------|
| Pi Zero 2 W | 512M | minimal | 64M | OK |
| Pi 3 1 GB | 1024M | minimal | 64M | OK |
| Any 2 GB+ | 2 GB+ | standard+ | 64–96M | OK |

**Both mode** (server + client with display on same Pi):

| Hardware | RAM | Profile | Server | Client | Total | % RAM | Status |
|----------|-----|---------|--------|--------|-------|-------|--------|
| Pi Zero 2 W | 512M | minimal | 592M | 352M | 944M | 303% | **Not supported** |
| Pi 3 1 GB | 1024M | minimal | 592M | 352M | 944M | 115% | **Not supported** |
| Pi 4 2 GB | 2048M | standard | 1,056M | 448M | 1,504M | 81% | Tight — works, limited headroom |
| Pi 4 4 GB+ | 4096M | performance | 1,376M | 672M | 2,048M | 53% | OK |

**Both mode** (server + headless client on same Pi):

| Hardware | RAM | Profile | Server | Client | Total | % RAM | Status |
|----------|-----|---------|--------|--------|-------|-------|--------|
| Pi Zero 2 W | 512M | minimal | 592M | 64M | 656M | 210% | **Not supported** |
| Pi 3 1 GB | 1024M | minimal | 592M | 64M | 656M | 80% | Tight — works, limited headroom |
| Pi 4 2 GB | 2048M | standard | 1,056M | 64M | 1,120M | 61% | OK |
| Pi 4 4 GB+ | 4096M | performance | 1,376M | 96M | 1,472M | 38% | OK |

> Services rarely hit their limits simultaneously — limits exist to prevent runaway processes from starving the host. A 74% limit-to-RAM ratio on Pi 4 2 GB is safe in practice.

## Firewall rules

If the host runs `ufw` or an equivalent, open these ports on the **server** side:

```bash
# Snapcast core
sudo ufw allow 1704/tcp   # Audio streaming
sudo ufw allow 1705/tcp   # JSON-RPC control
sudo ufw allow 1780/tcp   # HTTP API + Snapweb UI

# Audio sources
sudo ufw allow 4953/tcp   # TCP audio input (ffmpeg / Android streaming)
sudo ufw allow 5000/tcp   # AirPlay (shairport-sync RTSP)
sudo ufw allow 5858/tcp   # AirPlay cover art
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

Full port table (with direction and purpose): [USAGE.md](USAGE.md).

## Network QoS

For congested networks or installs where the same Pi sees bulk file transfers, `deploy.sh` configures `cake` qdisc with DSCP EF marking on snapcast ports (1704/1705) so audio packets keep low-latency priority during contention:

```bash
# Applied automatically by deploy.sh on supported kernels
tc qdisc add dev eth0 root cake bandwidth 100mbit
```

You can disable or tune via `.env` (`QOS_ENABLE=false`). On a quiet home LAN the effect is undetectable; under heavy parallel transfers it's the difference between glitch-free audio and dropouts.
