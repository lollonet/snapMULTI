🇬🇧 **English** | 🇮🇹 [Italiano](README.it.md)

# snapMULTI - Multiroom Audio Server

[![CI](https://github.com/lollonet/snapMULTI/actions/workflows/validate.yml/badge.svg)](https://github.com/lollonet/snapMULTI/actions/workflows/validate.yml)
[![release](https://img.shields.io/github/v/release/lollonet/snapMULTI?color=orange)](https://github.com/lollonet/snapMULTI/releases/latest)
[![downloads](https://img.shields.io/docker/pulls/lollonet/snapmulti-server?color=green)](https://hub.docker.com/r/lollonet/snapmulti-server)
[![Donate](https://img.shields.io/badge/Donate-PayPal-yellowgreen)](https://paypal.me/lolettic)
[![License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

Play music in sync across every room. Stream from Spotify, AirPlay, your music library, or any app — all speakers play together.

## How It Works

snapMULTI runs on a home server and streams audio to speakers throughout your network. Send music from any of these sources:

| Source | How to use |
|--------|------------|
| **Spotify** | Open Spotify app → Connect to a device → "<hostname> Spotify" (Premium required) |
| **Tidal** | Open Tidal app → Cast → "<hostname> Tidal" (ARM/Pi only) |
| **AirPlay** | iPhone/iPad/Mac → AirPlay → "<hostname> AirPlay" |
| **Music library** | Use [myMPD](http://server-ip:8180) web UI, or an MPD app ([Cantata](https://github.com/CDrummond/cantata), [MPDroid](https://play.google.com/store/apps/details?id=com.namelessdev.mpdroid)) → connect to your server |
| **Any app** | Stream via ffmpeg to port 4953 (see [Sources](docs/SOURCES.md#5-tcp-input-tcp-server)) |
| **Android** | See [streaming guide](docs/SOURCES.md#streaming-from-android) |

More source types available — see [Audio Sources Reference](docs/SOURCES.md).

### Switching Sources

Two web interfaces are available:

| Interface | URL | Purpose |
|-----------|-----|---------|
| **Snapweb** | `http://<server-ip>:1780` | Manage speakers: switch sources, adjust volume, group/ungroup |
| **myMPD** | `http://<server-ip>:8180` | Browse and play your music library (MPD source) |

You can also use the [Snapcast Android app](https://play.google.com/store/apps/details?id=de.badaix.snapcast).

## Quick Start

### Beginners: Plug-and-Play (Raspberry Pi)

Flash an SD card, run a short script, insert it, power on — done. You only need to copy-paste two commands on your computer (no Pi terminal needed).

**You need:**
- Raspberry Pi 4 (2GB+ RAM recommended)
- microSD card (16GB+)
- Another computer to prepare the SD card

**On your computer (macOS/Linux):**
```bash
# 1. Flash SD card with Raspberry Pi Imager (https://www.raspberrypi.com/software/)
#    - Choose OS: Raspberry Pi OS Lite (64-bit)
#    - Click Next → Edit Settings → set hostname, user/password, WiFi, enable SSH

# 2. Re-insert SD card, then run (requires Git — see docs/INSTALL.md Step 3 if not installed):
git clone --recurse-submodules https://github.com/lollonet/snapMULTI.git
./snapMULTI/scripts/prepare-sd.sh

# 3. Choose what to install when prompted:
#    1) Audio Player   — play music from your server on speakers
#    2) Music Server   — central hub for Spotify, AirPlay, etc.
#    3) Server+Player  — both on the same Pi

# 4. Eject SD, insert in Pi, power on
```

**On Windows (PowerShell):**
```powershell
# Requires Git for Windows: https://git-scm.com/download/win
Set-ExecutionPolicy -Scope CurrentUser RemoteSigned
git clone --recurse-submodules https://github.com/lollonet/snapMULTI.git
.\snapMULTI\scripts\prepare-sd.ps1
```

First boot installs everything automatically (~5–10 min). HDMI shows a progress screen. The Pi reboots when done.

> **Complete step-by-step instructions** (Imager screenshots, SD card mount points, all three OS): **[docs/INSTALL.md](docs/INSTALL.md)**

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

You should see six running containers: `snapserver`, `shairport-sync`, `librespot`, `mpd`, `mympd`, and `metadata`. On ARM (Raspberry Pi), you'll also see `tidal-connect` (seven total).

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
| **Spotify/AirPlay not visible** | Make sure the Pi and your phone are on the same WiFi network. Restart the Pi if needed |
| **No audio output** | SSH in and run `docker compose logs -f` to check for errors |
| **Containers keep restarting** | SSH in and run `docker compose logs -f` — common cause is missing config files |
| **Clients can't connect** | Ensure firewall allows ports 1704, 1705, 1780 (see [Firewall Rules](docs/HARDWARE.md#firewall-rules)) |
| **myMPD shows empty library** | Your music library may still be scanning — wait a few minutes, then refresh the page |
| **Audio out of sync** | Increase buffer in `config/snapserver.conf`: `buffer = 3000` (default: 2400) |

For detailed troubleshooting (mDNS, logs, diagnostics), see [Usage Guide](docs/USAGE.md#logs--diagnostics).

## Upgrading

SSH into your Pi (from your computer: `ssh <username>@<hostname>.local`), then run:

```bash
# Server
cd /opt/snapmulti
git pull
docker compose pull
docker compose up -d

# Client (if installed — disable read-only mode first: sudo ro-mode disable && sudo reboot)
cd /opt/snapclient
git pull
docker compose pull
docker compose up -d
```

For major version upgrades, check [CHANGELOG.md](CHANGELOG.md) for breaking changes. For details on Watchtower (automatic updates) and update.sh (config updates), see [Usage Guide — Updating](docs/USAGE.md#updating).

## Documentation

| Guide | What's inside |
|-------|---------------|
| [**Installation**](docs/INSTALL.md) | Complete step-by-step: Raspberry Pi Imager, SD card prep, first boot, verification — macOS/Linux/Windows |
| [Hardware & Network](docs/HARDWARE.md) | Server/client requirements, Raspberry Pi setups, network bandwidth, recommended configs |
| [Usage & Operations](docs/USAGE.md) | Architecture, services, MPD control, mDNS setup, deployment, CI/CD |
| [Audio Sources](docs/SOURCES.md) | All source types, parameters, JSON-RPC API, Android/Tidal streaming |
| [Changelog](CHANGELOG.md) | Version history |

## snapMULTI Ecosystem

| App | Platform | Description |
|-----|----------|-------------|
| [snapMULTI](https://github.com/lollonet/snapMULTI) | Raspberry Pi / Linux | Multiroom audio server (this project) |
| [snapclient-pi](https://github.com/lollonet/snapclient-pi) | Raspberry Pi | Audio player with cover display |

## Acknowledgments

snapMULTI is built on top of these open source projects:

- **[Snapcast](https://github.com/badaix/snapcast)** by Johannes Pohl — the multiroom audio streaming engine at the heart of this project
- **[go-librespot](https://github.com/devgianlu/go-librespot)** by devgianlu — Spotify Connect implementation
- **[shairport-sync](https://github.com/mikebrady/shairport-sync)** by Mike Brady — AirPlay audio receiver
- **[MPD](https://www.musicpd.org/)** — Music Player Daemon
- **[myMPD](https://github.com/jcorporation/myMPD)** by jcorporation — MPD web client
- **[tidal-connect](https://github.com/edgecrush3r/tidal-connect-docker)** by edgecrush3r — Tidal Connect for Raspberry Pi
