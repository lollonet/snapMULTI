🇬🇧 **English** | 🇮🇹 [Italiano](USAGE.it.md)

# Usage & Operations Guide

Operational reference for a running snapMULTI installation. For first-time install see [INSTALL.md](INSTALL.md). For hardware compatibility see [HARDWARE.md](HARDWARE.md).

## Architecture

Server stack (7 containers, host networking):

| Container | Role | Port |
|-----------|------|------|
| `snapserver` | Audio streaming + JSON-RPC control | 1704, 1705, 1780, 4953 |
| `mpd` | Music library playback (FIFO out) | 6600, 8000 |
| `mympd` | Web UI for MPD | 8180 |
| `shairport-sync` | AirPlay receiver (FIFO out) | 5000, 5858 |
| `librespot` | Spotify Connect (FIFO out) | 24879 + ephemeral |
| `tidal-connect` | Tidal Connect, ARM only (FIFO out) | 2019 |
| `metadata` | Cover art + track info | 8082 (WS), 8083 (HTTP) |

Audio chain: source → FIFO pipe in `/audio/` → snapserver → FLAC over network → snapclient → ALSA out. Unified format `44100:16:2` (44.1 kHz / 16-bit / stereo) across all sources, no resampling.

Client stack (3 containers on Pi 3/4/5; native snapclient `.deb` on Pi Zero 2W):
`snapclient` + `audio-visualizer` (port 8081) + `fb-display` (HDMI cover art).

## Audio Sources

9 sources defined in `config/snapserver.conf` (5 active, 4 available as commented examples):

| # | Stream ID | Type | How to play |
|---|-----------|------|-------------|
| 1 | `MPD` | pipe | myMPD web UI at `:8180`, or any MPD client (`mpc`, Cantata, MPDroid) on port `6600` |
| 2 | `Tidal` | pipe (ARM only) | Cast from the Tidal app — appears as `<hostname> Tidal` |
| 3 | `AirPlay` | pipe | Cast from iOS / macOS — appears as the server hostname |
| 4 | `Spotify` | pipe | Cast from any Spotify Premium app — appears as `<hostname> Spotify` |
| 5 | `TCP-Input` | tcp (server, :4953) | Stream raw PCM from anywhere: `ffmpeg ... tcp://<server>:4953` |
| 6 | `LineIn` | alsa | Capture from ALSA device. Uncomment in `snapserver.conf` |
| 7 | `AutoSwitch` | meta | Auto-failover across other streams. Uncomment in `snapserver.conf` |
| 8 | `Alert` | file | Play a fixed audio file on demand. Uncomment in `snapserver.conf` |
| 9 | `Remote` | tcp (client) | Pull from another TCP server. Uncomment in `snapserver.conf` |

Source-specific params (FIFO path, controlscript, sample format) live inline in `config/snapserver.conf` — that file is the authoritative reference.

### Customising device names

Spotify and Tidal default to `<hostname> Spotify` / `<hostname> Tidal`. Override via `.env`:

```bash
SPOTIFY_NAME="Living Room Spotify"
TIDAL_NAME="Living Room Tidal"
```

### Tidal Connect security note

<a id="tidal-security-note"></a>
Tidal Connect is **opt-in** (enable the `tidal` Compose profile). The upstream container is built on Raspbian Stretch (EOL 2019), pulls packages from `archive.debian.org` with `trusted=yes`, and contains a proprietary unmaintained binary. ARM only (no x86_64 build exists). Read the disclosure block in `docker-compose.yml` before enabling.

### Streaming from Android (no native cast)

| Method | App | Quality | Setup |
|--------|-----|---------|-------|
| AirPlay sender | AirMusic, AllStream | Good | Install app → select AirPlay target = the server hostname |
| TCP via BubbleUPnP | BubbleUPnP + ffmpeg relay | Good | Capture in BubbleUPnP, relay `ffmpeg ... tcp://server:4953` |
| Direct TCP | Termux + ffmpeg | Lossless | `ffmpeg -f pulse -i default -f s16le -ar 44100 -ac 2 tcp://server:4953` |

## Control Interfaces

| Interface | URL | What it does |
|-----------|-----|--------------|
| **Snapweb** | `http://<server>:1780` | Switch sources per speaker, group/ungroup, per-room volume |
| **myMPD** | `http://<server>:8180` | Browse music library, queues, playlists, cover art |
| **System status** | `http://<server>:8083/status` | Container + audio + NFS health (auto-refresh) |
| **Snapcast Android app** | [Play Store](https://play.google.com/store/apps/details?id=de.badaix.snapcast) | Mobile equivalent of Snapweb |

Quick rules:
- Play music from library → myMPD
- Switch a speaker's source → Snapweb or the Android app
- Cast from Spotify/AirPlay/Tidal → the source app picks the speaker
- Health check → `/status` page

### MPD from command line

```bash
sudo apt install mpc
mpc -h <server> play | pause | next | volume 50 | status
mpc -h <server> add "Artist/Album"
mpc -h <server> update                # rescan library (use sparingly on NFS — see "Updating" below)
```

### Switch source via JSON-RPC

```bash
# list streams
curl -s http://<server>:1780/jsonrpc -d \
  '{"id":1,"jsonrpc":"2.0","method":"Server.GetStatus"}' | jq '.result.server.streams[].id'

# switch a group
curl -s http://<server>:1780/jsonrpc -d \
  '{"id":1,"jsonrpc":"2.0","method":"Group.SetStream","params":{"id":"<GROUP_ID>","stream_id":"Spotify"}}'
```

Full JSON-RPC schema: [Snapcast wiki](https://github.com/badaix/snapcast/blob/master/doc/json_rpc_api/v2_0_0.md).

## Autodiscovery (mDNS)

Snapcast, AirPlay, Spotify and Tidal all advertise themselves on the LAN via the **host's** `avahi-daemon` (D-Bus socket bind-mounted into the relevant containers). Required at the host: `systemctl is-active avahi-daemon` returns `active`. **Do not run avahi-daemon inside containers** — port 5353 conflicts with the host.

Snapcast 0.35.x quits its Avahi poll loop on `AVAHI_CLIENT_FAILURE` with no retry. The systemd units include `PartOf=avahi-daemon.service` so a host avahi restart recreates the Compose stacks automatically (~3 s audio gap).

### Verify

```bash
avahi-browse -r _snapcast._tcp --terminate   # snapcast advertisement
avahi-browse -r _raop._tcp --terminate       # AirPlay
ss -tlnp | grep -E '1704|1705|1780'          # snapserver ports listening
```

### When discovery fails

1. Host avahi-daemon down → `sudo systemctl start avahi-daemon`
2. Apparmor blocked container → confirm `apparmor:unconfined` in `docker-compose.yml`
3. Different subnet → mDNS doesn't route across VLANs; use static IP in `.env`
4. Firewall → see [HARDWARE.md — Firewall Rules](HARDWARE.md#firewall-rules)

## Systemd Units

After install, systemd owns container lifecycle. ADR-005 — Docker `restart: unless-stopped` handles crashes, systemd handles boot.

Server: `snapmulti-server.service`, `snapmulti-status.timer`, `snapmulti-backup.timer`
Client: `snapclient.service` (or `snapclient.service` native on Pi Zero 2W), `snapclient-discover.timer`, `snapclient-display.service` (HDMI clients only)
All: `snapmulti-boot-tune.service` (CPU governor, USB autosuspend, WiFi powersave)

Unit files are installed by `firstboot.sh`. Inspect with `systemctl cat <unit>`.

## Logs & Diagnostics

```bash
# live logs (server)
cd /opt/snapmulti && docker compose logs -f
docker compose logs -f snapserver shairport-sync librespot mpd

# container health
docker compose ps
docker inspect --format='{{.State.Health.Status}}' snapserver

# system status page (browser)
http://<server>:8083/status
```

### Bundled diagnostic on failure

When `firstboot.sh` aborts (any step), its cleanup trap writes a redacted tarball to the FAT32 boot partition:

```
/boot/firmware/snapmulti-diag-install-failed-<UTC-ts>.tar.gz
```

Pull the SD out, mount on any computer, attach to a [GitHub issue](https://github.com/lollonet/snapMULTI/issues/new/choose). Anonymised: no MAC, no RFC1918 IPs, no SSID, no tokens. Manual invocation for support reports:

```bash
sudo /opt/snapmulti/scripts/diagnostic.sh --reason crash --out-dir /tmp
```

Source: [`scripts/diagnostic.sh`](../scripts/diagnostic.sh).

### Install log (Pi)

`cat /var/log/snapmulti-install.log` (writable layer survives until reboot — overlayroot wipes it on reboot, the boot-partition bundle persists).

## Deployment

snapMULTI is **reflash-first** (ADR-005, DEC-003). All config auto-detects on first boot.

| Path | Audience | Trigger |
|------|----------|---------|
| Zero-touch SD | Beginners | Flash + `prepare-sd.sh` + power on |
| `deploy.sh` on existing Linux host | Advanced | `git clone` + `bash scripts/deploy.sh` |
| Manual | Advanced | `git clone` + edit `.env` + `docker compose up -d` |
| Tag push CI | Maintainer | `git tag v* && git push --tags` |

Tag push triggers `build-push.yml` → multi-arch images (amd64 + arm64 native runners) → Docker Hub. Devices pick up `:latest` on next reflash.

### Update strategy

- **Primary**: reflash the SD. `scripts/backup-from-sd.sh` extracts `mpd.db` first so MPD does fast incremental scan, not hours of NFS rescan
- **In-place** (advanced): `cd /opt/snapmulti && docker compose pull && docker compose up -d`. Not officially supported — config drift between versions is your problem to resolve

### Docker images

`lollonet/snapmulti-{server,airplay,mpd,metadata,tidal}:latest` (Docker Hub, built in CI) + `ghcr.io/devgianlu/go-librespot` (upstream) + `ghcr.io/jcorporation/mympd/mympd` (upstream). Tidal is ARM-only.

### Read-only filesystem

After install completes, the rootfs is mounted read-only via overlayroot + fuse-overlayfs. Toggle for maintenance:

```bash
sudo /opt/snapmulti/scripts/ro-mode.sh disable   # reboot
# make changes
sudo /opt/snapmulti/scripts/ro-mode.sh enable    # reboot
```

Cmdline.txt is owned by `scripts/common/cmdline-manager.sh` — don't edit `/boot/firmware/cmdline.txt` by hand. See ADR-003 for rationale.

## Quick Troubleshooting

| Symptom | First check |
|---------|-------------|
| No audio out, all containers `healthy` | snapclient picked the wrong sound card — `snapclient --list` on the client to find your card name, set `SOUND_CARD` in client `.env` |
| Spotify/AirPlay/Tidal not showing in apps | mDNS — see [Autodiscovery](#autodiscovery-mdns) |
| MPD database empty, all files visible on NFS | `mpc -h <server> update`, watch `mpc status | grep updating_db`. If hours of D-state, copy a pre-built `mpd.db` instead |
| Container restart loop | `docker compose logs <name>` — check the system status page first to confirm which one |
| Pi Zero 2W booting then panic | Zram swap saturated the overlay — `tune_pi_zero_2w_swap_safety()` should mask it. Reflash to apply the fix |
| Install fails before SSH | Pull SD, find `snapmulti-diag-install-failed-*.tar.gz` on boot partition |
