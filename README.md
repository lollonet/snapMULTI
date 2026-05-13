🇬🇧 **English** | 🇮🇹 [Italiano](README.it.md)

# snapMULTI — Open-source Sonos alternative on Raspberry Pi

[![CI](https://github.com/lollonet/snapMULTI/actions/workflows/validate.yml/badge.svg)](https://github.com/lollonet/snapMULTI/actions/workflows/validate.yml)
[![release](https://img.shields.io/github/v/release/lollonet/snapMULTI?color=orange)](https://github.com/lollonet/snapMULTI/releases/latest)
[![Docker pulls](https://img.shields.io/docker/pulls/lollonet/snapmulti-server?color=green)](https://hub.docker.com/r/lollonet/snapmulti-server)
[![License GPL-3.0](https://img.shields.io/badge/license-GPL--3.0-blue.svg)](LICENSE)

Play music in sync across every room. Cast from **Spotify**, **AirPlay**, **Tidal**, or your music library — all speakers play together with sub-millisecond drift. Flash an SD card, boot, done. No cloud, no subscription, no telemetry.

<p align="center">
  <img src="docs/images/display-playing.png" alt="snapMULTI HDMI display: cover art + spectrum analyzer + track info" width="640">
</p>

## Why snapMULTI

| | snapMULTI | Sonos | Volumio | MoOde |
|---|---|---|---|---|
| **Cost per room** | ~€60 (Pi 4 + DAC HAT) | €200+ | ~€60 + Plus subscription for multi-room | ~€60 |
| **Open source** | ✅ GPL-3.0 | ❌ | Partial | ✅ |
| **Multi-room sync** | ✅ ~5 ms drift | ✅ proprietary | ✅ (Plus only) | ❌ single device |
| **Cloud-free** | ✅ all local | ❌ | Partial | ✅ |
| **Spotify / AirPlay / Tidal** | ✅ / ✅ / ✅ (ARM, opt-in) | ✅ | ✅ (Plus) | ✅ |
| **HDMI cover-art display** | ✅ built-in | ❌ | ❌ | ❌ |
| **Setup time** | ~10 min (zero-touch SD) | app wizard | ~30 min wizard | wizard |

Pick snapMULTI when you want multi-room **and** Pi-DIY **and** zero cloud **and** zero subscription, in one package.

## Quick start

You need: a Raspberry Pi 4 or 5 (2 GB+), a 16 GB+ microSD, and a computer (macOS / Linux / Windows) to prepare the card.

### 1. Flash the SD with Raspberry Pi Imager

- OS: **Raspberry Pi OS Lite (64-bit)**
- Click the gear icon (`Ctrl/Cmd+Shift+X`) and set: hostname, username + password, WiFi (or leave empty for Ethernet), **☑ Enable SSH (password)**

### 2. Get the snapMULTI files

Either `git clone https://github.com/lollonet/snapMULTI.git`, or download the [latest release ZIP](https://github.com/lollonet/snapMULTI/releases/latest) and rename the folder to `snapMULTI/`.

### 3. Re-insert the SD and run the prep script

Re-insert the freshly-flashed SD so the `bootfs` partition appears on your computer, then in the folder that *contains* `snapMULTI/`:

```bash
# macOS / Linux:
./snapMULTI/scripts/prepare-sd.sh

# Windows PowerShell:
.\snapMULTI\scripts\prepare-sd.ps1
```

The script asks: **Audio Player** (speaker only) / **Music Server** (Spotify+AirPlay+Tidal+library) / **Server + Player** (both on one Pi).

> First PowerShell run on Windows? `Set-ExecutionPolicy -Scope CurrentUser RemoteSigned`.

### 4. Boot the Pi

Eject SD, insert in the Pi, power on. Wait ~10 minutes. The first-boot installer runs without SSH, shows progress on HDMI if you have a screen attached. Done.

> **Detailed walk-through** with screenshots and troubleshooting: [docs/INSTALL.md](docs/INSTALL.md).
> **Compatibility matrix** (which Pi models, DAC HATs, network setups): [docs/HARDWARE.md](docs/HARDWARE.md).

## After install

Replace `hostname` with what you set in Step 1.

| URL | What it does |
|-----|--------------|
| `http://hostname.local:1780` | **Snapweb** — per-room volume, group speakers, switch source |
| `http://hostname.local:8180` | **myMPD** — browse and play music library |
| `http://hostname.local:8083/status` | **Health page** — container + audio + NFS status |

### Cast from your apps

| Source | How |
|--------|-----|
| **Spotify** | Open app → select "*hostname* Spotify" (Premium) |
| **AirPlay** | AirPlay icon → "*hostname* AirPlay" |
| **Tidal** | Cast to "*hostname* Tidal" (ARM/Pi only, **opt-in** — see [security note](docs/USAGE.md#tidal-connect-security-note)) |
| **Any app** | Stream raw PCM to port 4953 ([details](docs/USAGE.md#streaming-from-android-no-native-cast)) |

## Add speakers

Flash another SD → choose **Audio Player** → insert in any Pi. mDNS auto-discovers the server.

Or any Linux box: `sudo apt install snapclient`.

## Updating

Reflash the SD with the latest release — all config auto-detects on first boot. To keep your MPD music index across reflashes: `./scripts/backup-from-sd.sh` before flashing.

## Documentation

| Guide | What's inside |
|-------|--------------|
| [Installation](docs/INSTALL.md) | Step-by-step with troubleshooting and diagnostic recovery |
| [Hardware](docs/HARDWARE.md) | Pi models, DAC HATs, network, Pi Zero 2 W exceptions |
| [Usage & Ops](docs/USAGE.md) | Architecture, audio sources, MPD, mDNS, deployment, log/diagnostic recovery |
| [Changelog](CHANGELOG.md) | Version history |

## Contributing & security

PRs, bug reports and "show your setup" posts welcome — see [CONTRIBUTING.md](CONTRIBUTING.md). For security issues use the private flow in [SECURITY.md](SECURITY.md). [Code of Conduct](CODE_OF_CONDUCT.md) · [Third-party notices](THIRD-PARTY-NOTICES.md) · License `GPL-3.0-only`.

## Acknowledgments

Built on [Snapcast](https://github.com/badaix/snapcast) (Johannes Pohl), [go-librespot](https://github.com/devgianlu/go-librespot) (devgianlu), [shairport-sync](https://github.com/mikebrady/shairport-sync) (Mike Brady), [MPD](https://www.musicpd.org/), [myMPD](https://github.com/jcorporation/myMPD) (jcorporation), [tidal-connect](https://github.com/edgecrush3r/tidal-connect-docker) (edgecrush3r).
