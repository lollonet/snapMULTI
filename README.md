🇬🇧 **English** | 🇮🇹 [Italiano](README.it.md)

# snapMULTI — Multi-room audio for Raspberry Pi

[![CI](https://github.com/lollonet/snapMULTI/actions/workflows/validate.yml/badge.svg)](https://github.com/lollonet/snapMULTI/actions/workflows/validate.yml)
[![release](https://img.shields.io/github/v/release/lollonet/snapMULTI?color=orange)](https://github.com/lollonet/snapMULTI/releases/latest)
[![Docker pulls](https://img.shields.io/docker/pulls/lollonet/snapmulti-server?color=green)](https://hub.docker.com/r/lollonet/snapmulti-server)
[![License GPL-3.0](https://img.shields.io/badge/license-GPL--3.0-blue.svg)](LICENSE)

snapMULTI is for people who want an **open-source multi-room audio system** without hand-building the Linux audio stack. You still flash Raspberry Pi OS and answer a few setup questions; snapMULTI automates the hard parts — Snapcast, Docker, audio routing, service discovery (mDNS), read-only boot, and recovery diagnostics. Cast from **Spotify**, **AirPlay**, **Tidal**, or your music library; every speaker plays together with sub-millisecond drift. Local-first: no snapMULTI cloud or telemetry; the streaming services keep their own account requirements.

<p align="center">
  <img src="docs/images/display-playing.png" alt="snapMULTI HDMI display: cover art + spectrum analyzer + track info" width="640">
</p>

> **Sound output.** snapMULTI sends a line-level signal from the Pi — it does not amplify. You need one of:
> - an **active speaker** (built-in amp, e.g. Edifier R1280T, Audioengine A2+),
> - a **HAT with integrated amplifier** (e.g. [HiFiBerry AMP2](https://www.hifiberry.com/shop/boards/hifiberry-amp2/)) driving passive speakers,
> - a **DAC HAT** (e.g. HiFiBerry DAC+ / DAC2 Pro) into an external amplifier and passive speakers, or
> - a **digital HAT** (e.g. HiFiBerry Digi+) feeding an AV receiver over S/PDIF.
>
> Full setup examples and tested combinations: [docs/HARDWARE.md#recommended-setups](docs/HARDWARE.md#recommended-setups).

## Choose your setup

| Your situation | What to install on each Pi | Notes |
|----------------|----------------------------|-------|
| **One speaker, one room** | One Pi → choose **Audio Player** | Any Pi 3 B+ / 4 / 5 / Zero 2 W |
| **Server + one speaker on the same Pi** | One Pi → choose **Server + Player** | Pi 4 2 GB+ (Pi Zero 2 W not supported in this mode) |
| **Central server, speakers in other rooms** | One Pi → **Music Server**. Each speaker Pi → **Audio Player** | mDNS auto-discovers — speakers find the server on first boot |
| **Music library lives on a NAS** | Pick Music Server or Server + Player | `prepare-sd.sh` will ask for the NFS / SMB path. Have user / password ready for SMB |
| **You only have a Pi Zero 2 W as client** | Choose **Audio Player** | Auto-promoted to native snapclient — no Docker, no cover-art display. See [Pi Zero 2 W Notes](docs/HARDWARE.md#pi-zero-2-w-notes) |

## Realistic expectations

- **Time**: ~10–15 min from inserting the SD to hearing audio. First boot does the install over the network, then reboots once.
- **Skill floor**: you should be comfortable flashing an SD with Raspberry Pi Imager, finding your Pi by hostname (`.local`) or IP, and copying a small file off the SD card if something goes wrong. You do **not** need to know Docker, systemd, ALSA, or Snapcast — snapMULTI handles them.
- **SD card matters**: cheap microSDs are the #1 cause of "install hangs". Use a SanDisk / Samsung A1 (or better). 16 GB is the minimum.
- **Network**: 2.4 GHz works but 5 GHz or Ethernet is more stable. mDNS (`*.local`) must traverse the LAN (single subnet, no VLAN isolation).
- **Streaming services have their own requirements**: Spotify Connect needs Premium. Tidal Connect is ARM-only and opt-in (see [security note](docs/USAGE.md#tidal-connect-security-note)). AirPlay needs an Apple device.

## Quick start

Hardware checklist (Pi model, SD card, audio output) before you begin: [docs/HARDWARE.md](docs/HARDWARE.md).

### 1. Flash the SD with [Raspberry Pi Imager](https://www.raspberrypi.com/software/)

snapMULTI relies on the cloud-init metadata that Imager writes when you set hostname, user, WiFi and SSH below. **Plain image flashers (Balena Etcher, `dd`) won't work** — they copy bytes only, no metadata, so the Pi boots without network or login.

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

## If something fails

snapMULTI runs the install as a systemd service and captures everything as it goes. If the first boot aborts, the cleanup trap writes a redacted diagnostic bundle to the SD card's **boot partition** (FAT32, readable from any computer — no SSH needed):

```
/boot/firmware/snapmulti-diag-install-failed-<UTC-ts>.tar.gz
```

Pull the SD out, plug it into your laptop, attach the bundle to a [GitHub issue](https://github.com/lollonet/snapMULTI/issues/new/choose). The bundle is anonymised (no MAC, no LAN IPs, no SSID, no passwords, no API tokens) — safe to share publicly. Common symptoms and the smoke test (`scripts/device-smoke.sh`): [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md).

## Documentation

| Guide | When to open it |
|-------|-----------------|
| [Install](docs/INSTALL.md) | First-time setup — flash, boot, listen. The basic path |
| [Advanced](docs/ADVANCED.md) | Multi-room, NFS / SMB library, custom `.env`, manual deploy, read-only fs, MPD CLI, JSON-RPC |
| [Troubleshooting](docs/TROUBLESHOOTING.md) | Something failed — install, mDNS, audio, container restart loops |
| [Hardware](docs/HARDWARE.md) | Pi models, DAC HATs, network requirements, Pi Zero 2 W details |
| [Architecture](docs/USAGE.md) | How it's put together — services, ports, audio sources, security model |
| [Changelog](CHANGELOG.md) | Version history |

## Contributing & security

PRs, bug reports and "show your setup" posts welcome — see [CONTRIBUTING.md](CONTRIBUTING.md). For security issues use the private flow in [SECURITY.md](SECURITY.md). [Code of Conduct](CODE_OF_CONDUCT.md) · [Third-party notices](THIRD-PARTY-NOTICES.md) · License `GPL-3.0-only`.

## Acknowledgments

Built on [Snapcast](https://github.com/badaix/snapcast) (Johannes Pohl), [go-librespot](https://github.com/devgianlu/go-librespot) (devgianlu), [shairport-sync](https://github.com/mikebrady/shairport-sync) (Mike Brady), [MPD](https://www.musicpd.org/), [myMPD](https://github.com/jcorporation/myMPD) (jcorporation), [tidal-connect](https://github.com/edgecrush3r/tidal-connect-docker) (edgecrush3r).
