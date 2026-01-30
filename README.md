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
| **Spotify** | Open Spotify app → Connect to a device → "snapMULTI" (Premium required) |
| **AirPlay** | iPhone/iPad/Mac → AirPlay → "snapMULTI" |
| **Music library** | Use an MPD app ([Cantata](https://github.com/CDrummond/cantata), [MPDroid](https://play.google.com/store/apps/details?id=com.namelessdev.mpdroid)) → connect to your server |
| **Any app** | Stream audio via TCP to the server |
| **Android / Tidal** | See [streaming guide](docs/SOURCES.md#streaming-from-android) |

More source types available — see [Audio Sources Reference](docs/SOURCES.md).

## Quick Start

### You need

- A Linux machine (x86_64 or ARM64)
- Docker and Docker Compose installed
- A folder with your music files

### 1. Get the project

```bash
git clone https://github.com/lollonet/snapMULTI.git
cd snapMULTI
```

### 2. Configure

```bash
cp .env.example .env
```

Edit `.env` with your settings:

```bash
# Music library paths (host)
MUSIC_LOSSLESS_PATH=/path/to/your/music/Lossless
MUSIC_LOSSY_PATH=/path/to/your/music/Lossy

# Timezone
TZ=Your/Timezone

# User/Group for container processes (match your host user)
PUID=1000
PGID=1000
```

### 3. Start

```bash
docker compose up -d
```

### 4. Verify

```bash
docker ps
```

You should see two running containers: `snapserver` and `mpd`.

## Listen on Your Speakers

Install a Snapcast client on each device where you want audio.

**Debian / Ubuntu:**
```bash
sudo apt install snapclient
```

**Arch Linux:**
```bash
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

## Documentation

| Guide | What's inside |
|-------|---------------|
| [Hardware & Network](docs/HARDWARE.md) | Server/client requirements, Raspberry Pi setups, network bandwidth, recommended configs |
| [Usage & Operations](docs/USAGE.md) | Architecture, services, MPD control, mDNS setup, deployment, CI/CD |
| [Audio Sources](docs/SOURCES.md) | All source types, parameters, JSON-RPC API, Android/Tidal streaming |
| [Changelog](CHANGELOG.md) | Version history |
