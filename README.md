🇬🇧 **English** | 🇮🇹 [Italiano](README.it.md)

# snapMULTI - Multiroom Audio Server

[![CI/CD](https://github.com/lollonet/snapMULTI/actions/workflows/deploy.yml/badge.svg)](https://github.com/lollonet/snapMULTI/actions/workflows/deploy.yml)
[![SnapForge](https://img.shields.io/badge/part%20of-SnapForge-blue)](https://github.com/lollonet/snapforge)
[![License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

Play music in sync across every room. Stream from Spotify, AirPlay, your music library, or any app — all speakers play together.

## How It Works

snapMULTI runs on a home server and streams audio to speakers throughout your network. Send music from any of these sources:

| Source | How to use |
|--------|------------|
| **Spotify** | Open Spotify app → Connect to a device → "<hostname> Spotify" (Premium required) |
| **Tidal** | Open Tidal app → Cast → "<hostname> Tidal" (ARM/Pi only) |
| **AirPlay** | iPhone/iPad/Mac → AirPlay → "snapMULTI" |
| **Music library** | Use [myMPD](http://server-ip:8180) web UI, or an MPD app ([Cantata](https://github.com/CDrummond/cantata), [MPDroid](https://play.google.com/store/apps/details?id=com.namelessdev.mpdroid)) → connect to your server |
| **Any app** | Add TCP source to config, stream via ffmpeg (see [Sources](docs/SOURCES.md)) |
| **Android** | See [streaming guide](docs/SOURCES.md#streaming-from-android) |

More source types available — see [Audio Sources Reference](docs/SOURCES.md).

## Quick Start

### Beginners: Plug-and-Play (Raspberry Pi)

No terminal skills required. Flash an SD card, answer one question, insert it, power on — done.

**You need:**
- Raspberry Pi 4 (2GB+ RAM recommended)
- microSD card (16GB+)
- Another computer to prepare the SD card

**On your computer (macOS/Linux):**
```bash
# 1. Flash SD card with Raspberry Pi Imager
#    - Choose: Raspberry Pi OS Lite (64-bit)
#    - Configure: hostname, user/password, WiFi, SSH

# 2. Keep SD mounted, run:
git clone --recurse-submodules https://github.com/lollonet/snapMULTI.git
./snapMULTI/scripts/prepare-sd.sh

# 3. Choose what to install:
#    1) Audio Player   — play music from your server on speakers
#    2) Music Server   — central hub for Spotify, AirPlay, etc.
#    3) Server+Player  — both on the same Pi

# 4. Eject SD, insert in Pi, power on
```

**On Windows (PowerShell):**
```powershell
git clone --recurse-submodules https://github.com/lollonet/snapMULTI.git
.\snapMULTI\scripts\prepare-sd.ps1
```

First boot installs everything automatically (~5-10 min). HDMI shows a progress screen. The Pi reboots when done.

#### Connect Your Music

When you choose Music Server or Server+Player, the installer asks where your music is:

| Option | Best for | What happens |
|--------|----------|-------------|
| **Streaming only** | Spotify, AirPlay, Tidal users | No local files needed — just cast from your phone |
| **USB drive** | Portable collections | Plug the drive into the Pi before powering on |
| **Network share** | NAS or another computer | Enter your NFS or SMB server address during setup |
| **Set up later** | Not sure yet | Configure manually after install (see [USAGE.md](docs/USAGE.md)) |

> **Note**: For network shares with credentials, the password is temporarily stored on the SD card's boot partition during setup. It is automatically removed after the Pi completes its first boot. Keep the SD card secure until then.

---

### Advanced: Any Linux Server

For users comfortable with terminal and Docker. Works on **Raspberry Pi, x86_64, VMs, NAS** — anything that runs Linux and Docker.

**You need:**
- Any Linux machine (Pi4, Intel NUC, old laptop, VM, NAS with Docker support)
- Docker and Docker Compose installed
- A folder with your music files

Choose your method:

#### Option A: Automated (`deploy.sh`)

Auto-detects hardware, creates directories, sets permissions, starts services.

```bash
git clone https://github.com/lollonet/snapMULTI.git
cd snapMULTI
sudo ./scripts/deploy.sh
```

The script scans `/media/*`, `/mnt/*`, and `~/Music` for audio files. If not found, mount your music first:
```bash
sudo mount /dev/sdX1 /media/music   # USB drive, NAS, etc.
```

#### Option B: Manual

Full control — just clone, configure, run.

```bash
git clone https://github.com/lollonet/snapMULTI.git
cd snapMULTI
cp .env.example .env
```

Edit `.env` with your settings:

```bash
MUSIC_PATH=/media/music      # Path to your music library
TZ=Your/Timezone             # e.g., Europe/Rome
PUID=1000                    # Your user ID (run: id -u)
PGID=1000                    # Your group ID (run: id -g)
```

Start:

```bash
docker compose up -d
```

Verify:

```bash
docker ps
```

You should see six running containers: `snapserver`, `shairport-sync`, `librespot`, `mpd`, `mympd`, and `metadata`. On ARM (Raspberry Pi), you'll also see `tidal-connect`.

---

### Control your music

Open `http://<server-ip>:8180` in a browser — myMPD lets you browse and play your library from any device.

## Listen on Your Speakers

### Option A: Dedicated Pi Speaker (recommended)

Use `prepare-sd.sh` and choose "Audio Player" to turn another Pi into a speaker. It auto-discovers the server, displays cover art on HDMI (served by the server's metadata service), and supports audio HATs.

### Option B: Manual Snapclient

Install a Snapcast client on any Linux device:

```bash
# Debian/Ubuntu
sudo apt install snapclient

# Arch Linux
sudo pacman -S snapcast
```

Then run:

```bash
snapclient
```

It auto-discovers the server on your local network. To connect manually:

```bash
snapclient --host <server-ip>
```

## Troubleshooting

| Problem | Solution |
|---------|----------|
| **Spotify/AirPlay not visible** | Check mDNS: `avahi-browse -r _spotify-connect._tcp` — ensure host has `avahi-daemon` running |
| **No audio output** | Verify FIFO exists: `ls -la audio/*_fifo` — deploy.sh creates these automatically |
| **Containers keep restarting** | Check logs: `docker compose logs -f` — common cause is missing config files |
| **Clients can't connect** | Verify ports: `ss -tlnp \| grep 1704` — ensure firewall allows ports 1704, 1705, 1780 |
| **myMPD shows empty library** | Update database: `echo 'update' \| nc localhost 6600` — wait for scan to complete |
| **Audio out of sync** | Increase buffer in `config/snapserver.conf`: `buffer = 3000` (default: 2400) |

For detailed troubleshooting, see [Usage Guide — Autodiscovery](docs/USAGE.md#autodiscovery-mdns).

## Upgrading

Git is installed automatically during setup, so you can update directly on the Pi:

```bash
# Server
cd /opt/snapmulti
git pull
docker compose pull
docker compose up -d

# Client (if installed)
cd /opt/snapclient
git pull
docker compose pull
docker compose up -d
```

For major version upgrades, check [CHANGELOG.md](CHANGELOG.md) for breaking changes.

## Documentation

| Guide | What's inside |
|-------|---------------|
| [Hardware & Network](docs/HARDWARE.md) | Server/client requirements, Raspberry Pi setups, network bandwidth, recommended configs |
| [Usage & Operations](docs/USAGE.md) | Architecture, services, MPD control, mDNS setup, deployment, CI/CD |
| [Audio Sources](docs/SOURCES.md) | All source types, parameters, JSON-RPC API, Android/Tidal streaming |
| [Changelog](CHANGELOG.md) | Version history |
