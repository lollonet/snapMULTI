🇬🇧 **English** | 🇮🇹 [Italiano](README.it.md)

# snapMULTI — Multi-room audio for Raspberry Pi

[![CI](https://github.com/lollonet/snapMULTI/actions/workflows/validate.yml/badge.svg)](https://github.com/lollonet/snapMULTI/actions/workflows/validate.yml)
[![release](https://img.shields.io/github/v/release/lollonet/snapMULTI?color=orange)](https://github.com/lollonet/snapMULTI/releases/latest)
[![Docker pulls](https://img.shields.io/docker/pulls/lollonet/snapmulti-server?color=green)](https://hub.docker.com/r/lollonet/snapmulti-server)
[![License GPL-3.0](https://img.shields.io/badge/license-GPL--3.0-blue.svg)](LICENSE)

snapMULTI is for people who want an **open-source multi-room audio system** without hand-building the Linux audio stack. You still flash Raspberry Pi OS, download the software (a ZIP release, or git if you're comfortable with the command line), and answer a few questions about your setup; snapMULTI automates the hard parts — Snapcast, Docker, audio routing, service discovery (mDNS), read-only boot, and recovery diagnostics. Cast from **Spotify**, **AirPlay**, **Tidal**, or your music library; every speaker plays together with sub-millisecond drift. The streaming services keep their own account requirements.

<p align="center">
  <img src="docs/images/display-playing.png" alt="snapMULTI HDMI display: cover art + spectrum analyzer + track info" width="640">
</p>

> **Sound output.** snapMULTI sends a line-level signal from the Pi — it does not amplify. You need one of:
> - an **active speaker** (built-in amp, e.g. Edifier R1280T, Audioengine A2+),
> - a **validated DAC HAT** (HiFiBerry DAC+ family or InnoMaker PCM5122) into an external amplifier and passive speakers,
> - a **validated digital HAT** (HiFiBerry Digi+ family) feeding an AV receiver over S/PDIF, or
> - a manually configured output (USB DAC, HDMI, Pi jack, amplifier HAT) if you are comfortable troubleshooting audio hardware.
>
> Full setup examples, validation status and experimental outputs: [docs/HARDWARE.md#recommended-setups](docs/HARDWARE.md#recommended-setups).

## Who is this for

| Audience | Fit | What we promise |
|----------|-----|-----------------|
| **Maker / self-hosted / Home Assistant** | Primary | Local control, cheap hardware, integration with the rest of your self-hosted stack. Comfortable with SD flashing + a terminal. |
| **Linux-friendly audio enthusiast** | Secondary | A multi-room system that does not depend on a vendor app. Best fit if you already run MPD / Snapcast and want better orchestration. |
| **Small professional environments** (coworking, B&B, studios) | Opportunistic, not a target | Realistic only if you have an in-house tech or integrator — snapMULTI provides no SLA and no commercial support. |

snapMULTI is not "open Sonos". It is a community-maintained appliance for people who want full control of their local audio.

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
- **Network**: 2.4 GHz works but 5 GHz or Ethernet is more stable.
- **Privacy**: snapMULTI has no telemetry, no hosted snapMULTI cloud, and no account system. It runs on your LAN. Install/update steps still download packages and Docker images, and streaming integrations contact their own providers (Spotify, Tidal, Apple/AirPlay, metadata/artwork sources).
- **Streaming services have their own requirements**: Spotify Connect needs Premium. Tidal Connect runs only on ARM (the Raspberry Pi CPU architecture — so it works on any Pi, but not on an x86 server) and is enabled by default on Pi installs (opt-out by removing `tidal` from `COMPOSE_PROFILES`, see [security note](docs/USAGE.md#tidal-connect-security-note)). AirPlay needs an Apple device.

## Recommended first build

If this is your first snapMULTI install, use the boring path: **Raspberry Pi 4 (4 GB)**, a good **A1/A2 microSD**, Ethernet if you can, and a known-good DAC / amp path from [Hardware](docs/HARDWARE.md). Avoid making the first build a Pi Zero 2 W server, a weak PSU experiment, or a complex NAS+WiFi+unknown-HAT setup. Get one clean success first, then expand.

## Known limitations

- **Pi Zero 2 W** is supported as a headless Audio Player only; it is not a server or "Server + Player" target.
- **NAS share paths with spaces** are rejected. Rename `Music Share` to `Music_Share` on the NAS side.
- **Tidal Connect** uses an upstream proprietary component. It is enabled by default on ARM installs; remove `tidal` from `COMPOSE_PROFILES` in `/opt/snapmulti/.env` if you want a fully free-software stack.
- **Updates are reflash-first**. The filesystem is read-only, so you update by re-flashing the SD with a new release (~15-20 min on Pi 4/5, settings auto-detect) rather than patching a running system.
- **Hardware quality matters**. Bad SD cards, weak PSUs and flaky WiFi cause most first-install failures.

## Quick start

Hardware checklist (Pi model, SD card, audio output) before you begin: [docs/HARDWARE.md](docs/HARDWARE.md).

### 1. Flash the SD with [Raspberry Pi Imager](https://www.raspberrypi.com/software/)

snapMULTI relies on the cloud-init metadata that Imager writes when you set hostname, user, WiFi and SSH below. **Plain image flashers (Balena Etcher, `dd`) won't work** — they copy bytes only, no metadata, so the Pi boots without network or login.

- OS: **Raspberry Pi OS Lite (64-bit)**
- Click the gear icon (`Ctrl/Cmd+Shift+X`) and set: hostname, username + password, WiFi (or leave empty for Ethernet), **☑ Enable SSH (password)**

### 2. Get the snapMULTI files

For a first install, download and extract the [latest release ZIP](https://github.com/lollonet/snapMULTI/releases/latest). Use `git clone https://github.com/lollonet/snapMULTI.git` only if you already use Git or plan to contribute. The folder name does not matter — `prepare-sd.sh` resolves its own path.

### 3. Re-insert the SD and run the prep script

Re-insert the freshly-flashed SD. On macOS a *"The disk you inserted was not readable"* pop-up may appear for the Pi's Linux partition — click **Ignore**; the `bootfs` partition still mounts.

If you downloaded the ZIP, extract it first. Open a terminal (**Terminal** on macOS/Linux, **PowerShell** on Windows), `cd` into the snapMULTI folder you cloned or extracted, then run:

```bash
# macOS / Linux:
./scripts/prepare-sd.sh
# permission denied? run: bash scripts/prepare-sd.sh

# Windows PowerShell:
.\scripts\prepare-sd.ps1
```

The script walks you through a few questions: the role (**Audio Player** / **Music Server** / **Server + Player**), the music source (streaming / USB / NAS), the audio output (auto-detect or pick a HAT), the NAS connection details if you chose a network library, and optional advanced settings (read-only mode, image tag). Defaults are sane — you can press Enter through most of it.

> First PowerShell run on Windows? `Set-ExecutionPolicy -Scope CurrentUser RemoteSigned`.

### 4. Boot the Pi

Eject the SD, insert it in the Pi, power on. Wait roughly 15-20 minutes on a Pi 4/5 (longer on Pi 3 or Pi Zero 2 W) — the first-boot installer runs on its own (no SSH), shows progress on HDMI if a screen is attached, then reboots once. The HDMI progress display shows the expected total time so you know whether 8 minutes in is "almost there" or "barely halfway".

**It worked when**: with a screen attached, the HDMI display shows the snapMULTI now-playing screen (cover art / spectrum). Either way, from another device open `http://<hostname>.local:8083/`, then open **Status** — every check should be green. Then cast something (see **After install** below).

> **Detailed walk-through** with troubleshooting and the diagnostic-bundle recovery path: [docs/INSTALL.md](docs/INSTALL.md).
> **Hardware policy** (validated vs experimental Pi/audio combinations): [docs/HARDWARE.md](docs/HARDWARE.md).

## After install

Replace `hostname` with what you set in Step 1.

| URL | What it does |
|-----|--------------|
| `http://hostname.local:8083/` | **Start here** — links to every snapMULTI web page and API |
| `http://hostname.local:1780` | **Snapweb** — per-room volume, group speakers, switch source |
| `http://hostname.local:8180` | **myMPD** — browse and play music library |
| `http://hostname.local:8083/status` | **Status page** — container + audio + NFS status |

### Cast from your apps

| Source | How |
|--------|-----|
| **Spotify** | Open app → select "*hostname* Spotify" (Premium) |
| **AirPlay** | AirPlay icon → "*hostname* AirPlay" |
| **Tidal** | Cast to "*hostname* Tidal" (ARM/Pi only, **enabled by default** — see [security note](docs/USAGE.md#tidal-connect-security-note) to opt-out) |
| **Any app** | Stream raw PCM to port 4953 ([details](docs/USAGE.md#streaming-from-android-no-native-cast)) |

## Add speakers

Flash another SD → choose **Audio Player** → insert in any Pi. mDNS auto-discovers the server.

Or any Linux box: `sudo apt install snapclient`.

## Updating

snapMULTI updates by re-flashing, not by patching. The Pi runs a read-only filesystem (a power cut can't corrupt it), so there is no in-place upgrade — you write the latest release onto the SD again, exactly like the first time. It takes the same ~10–15 min, and every setting (role, audio HAT, NAS path, network) is auto-detected on first boot, so you reconfigure nothing.

Before re-flashing, run `./scripts/backup-from-sd.sh` to preserve your MPD music index — otherwise the library re-scan starts from scratch.

## If something fails

**Installed but you can't reach it?** If the Pi finished but `http://<hostname>.local:8083/` won't load: find the Pi's IP address in your router's device list and use that instead. `.local` (mDNS) name resolution fails on some Windows setups and on guest / mesh / VLAN Wi-Fi that isolates clients — keep the Pi and your phone/laptop on the same ordinary network. More mDNS help: [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md).

If the first boot itself aborted: snapMULTI runs the install as a systemd service and captures everything as it goes. The cleanup trap writes a redacted diagnostic bundle to the SD card's **boot partition** (FAT32, readable from any computer — no SSH needed):

```
/boot/firmware/snapmulti-diag-install-failed-<UTC-ts>.tar.gz
```

Pull the SD out, plug it into your laptop, attach the bundle to a [GitHub issue](https://github.com/lollonet/snapMULTI/issues/new/choose). The bundle is anonymised (no MAC, no LAN IPs, no SSID, no passwords, no API tokens) — safe to share publicly. Common symptoms and the smoke test (`scripts/device-smoke.sh`): [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md).

## Glossary

Quick definitions of terms you'll see in this README and the docs.

| Term | What it is |
|------|------------|
| **Server** | The Raspberry Pi (or any Linux box) that hosts the music sources — Snapcast, MPD, Spotify Connect, AirPlay, Tidal — and fans audio out to one or more speakers |
| **Audio Player** *(or "client" / "speaker")* | A Raspberry Pi that receives audio from the server and plays it through an attached DAC / amp / speaker. One per room |
| **Snapcast** | The open-source multi-room sync engine snapMULTI is built on. Server-side: `snapserver`; client-side: `snapclient` |
| **HAT** | "Hardware Attached on Top" — a small board that plugs onto the Pi's GPIO header. snapMULTI launch validation covers specific audio HAT families; see the hardware policy before buying |
| **mDNS** / `.local` | "Multicast DNS" — how devices announce themselves on the LAN without manual IP setup. `pi-server.local` resolves automatically on most networks |
| **NAS** | Network-attached storage — a separate box (Synology, QNAP, custom) hosting your music library, mounted by snapMULTI over NFS or SMB |
| **Read-only filesystem** | snapMULTI mounts the root filesystem read-only after install (overlayroot + fuse-overlayfs) so a power cut can't corrupt the SD card. Changes are wiped on reboot unless you toggle off RO mode |
| **Diagnostic bundle** | Anonymised tarball on the SD's boot partition (`snapmulti-diag-*.tar.gz`) — written automatically when an install fails, attachable to a GitHub issue without leaking secrets |

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
