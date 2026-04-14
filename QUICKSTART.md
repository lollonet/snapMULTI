# Quick Start

Turn a Raspberry Pi into a multiroom audio system. Cast from Spotify, AirPlay, or your music library to speakers in every room.

## What You Need

- Raspberry Pi 4 or 5 (2 GB+ RAM)
- microSD card (16 GB+)
- A computer to prepare the SD card

## Install (5 minutes)

**Step 1** — Flash SD card with [Raspberry Pi Imager](https://www.raspberrypi.com/software/):
- Choose **Raspberry Pi OS Lite (64-bit)**
- Set hostname, username/password, WiFi, enable SSH

**Step 2** — Remove SD, re-insert, then run:

```bash
git clone https://github.com/lollonet/snapMULTI.git
./snapMULTI/scripts/prepare-sd.sh
```

Choose what to install:
1. **Audio Player** — a speaker that plays from your server
2. **Music Server** — Spotify, AirPlay, Tidal, music library
3. **Server + Player** — both on one Pi

**Step 3** — Insert SD in Pi, power on. Wait ~10 minutes. Done.

## Play Music

| Source | How |
|--------|-----|
| **Spotify** | Open app, select device: "*hostname* Spotify" |
| **AirPlay** | AirPlay icon, select "*hostname* AirPlay" |
| **Music library** | Browse at `http://hostname.local:8180` |

Manage speakers at `http://hostname.local:1780`

## Add More Speakers

Flash another SD card, choose "Audio Player", insert in any Pi. It finds the server automatically.

## Updating

Reflash the SD card with the latest version. That's it.

If you have a music library (NFS/USB), extract the database first so MPD doesn't rescan:
```bash
./scripts/backup-from-sd.sh    # reads backup from old SD
# flash with Imager, then:
./scripts/prepare-sd.sh        # includes database automatically
```

---

**Problems?** See the [full install guide](docs/INSTALL.md).
**Hardware details?** See [hardware guide](docs/HARDWARE.md).
**Windows?** Use `.\snapMULTI\scripts\prepare-sd.ps1` in PowerShell.
