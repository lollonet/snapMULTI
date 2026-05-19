🇬🇧 **English** | 🇮🇹 [Italiano](USAGE.it.md)

# Architecture Reference

The "how it's put together" reference — services, ports, audio sources, security model, mDNS, systemd units. This file is **not a how-to**. For operational procedures (multi-room, NFS, custom `.env`, manual deploy, MPD CLI, JSON-RPC) see [ADVANCED.md](ADVANCED.md). For first-time install see [INSTALL.md](INSTALL.md). For failures see [TROUBLESHOOTING.md](TROUBLESHOOTING.md). For hardware compatibility see [HARDWARE.md](HARDWARE.md).

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
| `metadata` | Cover art + track info | 8082 (WS), 8083 (HTTP) — see [CLIENT-METADATA.md](CLIENT-METADATA.md) for integration patterns |

Audio chain: source → FIFO pipe in `/audio/` → snapserver → FLAC over network → snapclient → ALSA out. Unified format `44100:16:2` (44.1 kHz / 16-bit / stereo) across all sources, no resampling.

Client stack (3 containers on Pi 3/4/5; native snapclient `.deb` on Pi Zero 2W):
`snapclient` + `audio-visualizer` (port 8081) + `fb-display` (HDMI cover art).

## Container security model

Defaults applied to every container in `docker-compose.yml`:

| Setting | Value | Why |
|---------|-------|-----|
| `cap_drop` | `ALL` | Containers don't need root capabilities for audio routing |
| `read_only` | `true` + tmpfs at `/tmp` / `/run` | Compromised process can't write to image or persist code |
| `no-new-privileges` | `true` | Setuid binaries inside the container can't escalate |
| `user` | `PUID:PGID` (default `1000:1000`) | Non-root process inside the container |
| Resource limits | mem + CPU per service in `deploy.resources` | One runaway container can't starve the rest |

**Exception 1 — D-Bus / Avahi containers** (`snapserver`, `shairport-sync`, `librespot`): need `apparmor:unconfined` to access the host's D-Bus socket for mDNS advertisement (Avahi) and `cap_add: DAC_OVERRIDE` to write to the named-pipe FIFOs owned by the host's `PUID` user. AppArmor in the default Ubuntu profile blocks the D-Bus connection otherwise. `mpd` mounts the same Avahi/D-Bus sockets but keeps the default AppArmor profile — it does not require `apparmor:unconfined`. Everything else stays dropped.

**Exception 2 — `tidal-connect`** (ARM only): runs as root because the proprietary upstream binary needs it. **Enabled by default on ARM installs** — `deploy.sh` writes `COMPOSE_PROFILES=tidal` into `/opt/snapmulti/.env` so the `tidal` profile is active out of the box on Pi 3/4/5. To **opt out** (e.g. for a fully free-software stack), remove `tidal` from `COMPOSE_PROFILES` in `/opt/snapmulti/.env` and run `sudo systemctl restart snapmulti-server.service`. See [Tidal Connect security note](#tidal-connect-security-note) for the full disclosure.

**Privacy / telemetry**: snapMULTI itself does not phone home. There is no snapMULTI cloud service, hosted control plane, telemetry endpoint, analytics SDK, or snapMULTI account. Runtime control and metadata APIs are local LAN services. External network traffic still exists for normal dependencies and chosen integrations: OS/Docker downloads during install/update, Docker Hub image pulls, Spotify/Tidal/AirPlay provider traffic, and metadata/artwork lookups.

**Threat model**: snapMULTI is designed for a trusted LAN — server and clients on the same subnet behind a residential router. Out-of-scope: WAN exposure (no authentication on JSON-RPC, Snapweb or myMPD), multi-tenant scenarios, malicious clients on the LAN. If you need any of those, put a reverse proxy with auth in front and use `bind 127.0.0.1` in `config/snapserver.conf`.

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

Spotify and Tidal default to `<hostname> Spotify` / `<hostname> Tidal`. Override via `SPOTIFY_NAME` / `TIDAL_NAME` in `.env` — see [ADVANCED.md — Custom config](ADVANCED.md#custom-config--env-files).

### Tidal Connect security note

<a id="tidal-connect-security-note"></a>
Tidal Connect is **enabled by default on ARM installs** (`deploy.sh` writes `COMPOSE_PROFILES=tidal` to `/opt/snapmulti/.env` on Pi 3/4/5). To opt out for a fully free-software stack, remove `tidal` from `COMPOSE_PROFILES` in `/opt/snapmulti/.env` and restart `snapmulti-server.service`. The upstream container is built on Raspbian Stretch (EOL 2019), pulls packages from `archive.debian.org` with `trusted=yes`, and contains a proprietary unmaintained binary. ARM only (no x86_64 build exists). Read the disclosure block in `docker-compose.yml` before keeping it enabled.

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

Power-user commands (MPD CLI, JSON-RPC source switching, custom `.env`): [ADVANCED.md](ADVANCED.md).

## Autodiscovery (mDNS)

Snapcast, AirPlay, Spotify and Tidal advertise themselves on the LAN via the **host's** `avahi-daemon` (D-Bus socket bind-mounted into the relevant containers). Required at the host: `systemctl is-active avahi-daemon` returns `active`. **Do not run avahi-daemon inside containers** — port 5353 conflicts with the host.

Snapcast 0.35.x quits its Avahi poll loop on `AVAHI_CLIENT_FAILURE` with no retry. As of v0.7.5 the systemd units no longer use `PartOf=avahi-daemon.service` — that cascade was too aggressive (any host avahi restart tore down the whole Compose stack). Recovery is now explicit and operator-initiated: `scripts/common/system-tune.sh::tune_avahi_daemon` restarts `avahi-daemon` and then explicitly restarts `snapmulti-server.service` + `snapclient.service` so the libavahi-client connections inside snapcast are re-established. Routine `ExecStop` is `docker compose stop -t 5` (non-destructive), so a clean start cycle is 2–5 s instead of the 30–40 s teardown of the previous `compose down` model.

Quick verify:

```bash
avahi-browse -r _snapcast._tcp --terminate
avahi-browse -r _raop._tcp --terminate
ss -tlnp | grep -E '1704|1705|1780'
```

When discovery fails, see [TROUBLESHOOTING.md](TROUBLESHOOTING.md) — the relevant sections are "Device doesn't show up on the network / `.local` doesn't resolve" (your Pi is invisible to clients), "Speakers don't find the server (snapclient won't connect)" (snapclient discovery), and "Spotify / AirPlay / Tidal not visible in the casting app" (source-app discovery).

## Systemd Units

systemd owns container lifecycle after install (ADR-005). Docker `restart: unless-stopped` handles crashes, systemd handles boot.

- Server: `snapmulti-server.service`, `snapmulti-status.timer`, `snapmulti-backup.timer`
- Client: `snapclient.service`, `snapclient-discover.timer`, `snapclient-display.service` (HDMI clients only)
- All: `snapmulti-boot-tune.service`

Inspect with `systemctl cat <unit>`. Deployment paths and update strategy: [ADVANCED.md](ADVANCED.md#deployment-without-prepare-sd).

## Logs & Diagnostics

```bash
# server live logs
cd /opt/snapmulti && docker compose logs -f
docker compose logs -f snapserver shairport-sync librespot mpd

# container health
docker compose ps
docker inspect --format='{{.State.Health.Status}}' snapserver

# system status page (browser)
http://<server>:8083/status
```

Install-time and post-install failures (with the diagnostic bundle workflow): [TROUBLESHOOTING.md](TROUBLESHOOTING.md).
