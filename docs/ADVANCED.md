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
| SMB / CIFS | Windows share, Synology / QNAP with username + password | Credentials stay on root-only ext4, never on the FAT32 boot partition |
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
