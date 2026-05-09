🇬🇧 **English** | 🇮🇹 [Italiano](README.it.md)

# snapMULTI - Multiroom Audio Server

[![CI](https://github.com/lollonet/snapMULTI/actions/workflows/validate.yml/badge.svg)](https://github.com/lollonet/snapMULTI/actions/workflows/validate.yml)
[![release](https://img.shields.io/github/v/release/lollonet/snapMULTI?color=orange)](https://github.com/lollonet/snapMULTI/releases/latest)
[![downloads](https://img.shields.io/docker/pulls/lollonet/snapmulti-server?color=green)](https://hub.docker.com/r/lollonet/snapmulti-server)
[![Donate](https://img.shields.io/badge/Donate-PayPal-yellowgreen)](https://paypal.me/lolettic)
[![License](https://img.shields.io/badge/license-GPL--3.0-blue.svg)](LICENSE)

License: `GPL-3.0-only` · [Code of Conduct](CODE_OF_CONDUCT.md) · [Third-party notices](THIRD-PARTY-NOTICES.md)

Play music in sync across every room. Stream from Spotify, AirPlay, your music library, or any app — all speakers play together.

**What it is**: a Sonos-style multiroom audio system you build yourself with Raspberry Pis (~€60 per room with a DAC HAT). All open source, no cloud, no subscription, no telemetry. Flash an SD card, boot, done.

<p align="center">
  <img src="docs/images/display-playing.png" alt="snapMULTI playing Nirvana — cover art, spectrum analyzer, track info" width="720">
  <br>
  <em>HDMI display: cover art, spectrum analyzer, track metadata — rendered directly to framebuffer, no desktop needed</em>
</p>

## How it works

```text
   Spotify   AirPlay   Tidal   myMPD web UI   any TCP audio app
      │         │        │           │                │
      └─────────┴────────┴───────────┴────────────────┘
                              │
                              ▼
                    ┌───────────────────┐
                    │  Server (Pi / NUC)│  mixes sources, encodes once,
                    │  snapserver       │  fans out a single audio stream
                    └───────────────────┘
                              │  Snapcast over LAN (TCP/UDP)
                              ▼
              ┌───────────┬───────────┬──────────────┐
              │  Pi #1    │  Pi #2    │  Pi #N       │  each runs snapclient
              │  Living   │  Kitchen  │  Bedroom     │  + a DAC HAT or USB DAC
              └───────────┴───────────┴──────────────┘
                              │
                              ▼
                          🔊 Speakers
```

All clients play in lock-step (~5 ms drift across rooms). Add a client by flashing another SD and inserting it in any Pi — no IP config, no pairing, mDNS auto-discovers the server. Server and one client can run on the same Pi (`both` mode).

## Why snapMULTI

| | snapMULTI | Sonos | Volumio | MoOde |
|---|---|---|---|---|
| **Cost per room** | ~€60 (Pi 4 + DAC HAT) | €200+ (One SL) | ~€60 hardware + Volumio Plus subscription for multi-room | ~€60 hardware |
| **Open source** | ✅ GPL-3.0 | ❌ proprietary | Partial (multi-room is paid) | ✅ |
| **Multi-room sync** | ✅ Snapcast (~5 ms) | ✅ proprietary | ✅ (with Plus) | ❌ single device |
| **Cloud-free** | ✅ all local | ❌ Sonos cloud required | Partial | ✅ |
| **Telemetry** | ❌ none, none planned | ✅ collected by default | Partial | ❌ |
| **Spotify Connect** | ✅ Premium | ✅ | ✅ (Plus) | ✅ |
| **AirPlay** | ✅ AirPlay 1 | ✅ AirPlay 2 | ✅ (Plus) | ✅ |
| **Tidal Connect** | ✅ (ARM only, opt-in) | ✅ | ✅ (Plus) | ✅ |
| **HDMI cover-art display** | ✅ built-in fb-display | ❌ | ❌ | ❌ |
| **Setup** | flash SD → boot → done (~10 min) | app setup | wizard (~30 min) | wizard |
| **First-party hardware** | none — bring your own Pi | required | none | none |

Pick snapMULTI when you want **multi-room + Pi-DIY + zero cloud + zero subscription** in one package. Pick Sonos when you want plug-and-play and don't mind the price tag and the cloud lock-in. Pick Volumio Plus when you already own its hardware and the multi-room subscription is OK with you.

## Sources

| Source | How |
|--------|-----|
| **Spotify** | Open app → select "*hostname* Spotify" (Premium) |
| **AirPlay** | AirPlay icon → select "*hostname* AirPlay" |
| **Tidal** | Open app → cast to "*hostname* Tidal" (ARM/Pi only, **opt-in** — see [security note](docs/SOURCES.md#2-tidal-connect-pipe-from-tidal-connect)) |
| **Music library** | Browse at `http://hostname.local:8180` |
| **Any app** | Stream to port 4953 ([details](docs/SOURCES.md#5-tcp-input-tcp-server)) |

Manage speakers at `http://hostname.local:1780`
Check system health at `http://hostname.local:8083`

> **Full port reference**: see [`docs/USAGE.md#services--ports`](docs/USAGE.md#services--ports) for the complete list of ports, protocols, and what each container exposes.

## Quick Start

**[QUICKSTART.md](QUICKSTART.md)** — zero to music in 5 minutes.

### Raspberry Pi (beginners)

```bash
# Flash SD with Pi Imager (64-bit Lite, set hostname/WiFi/SSH)
# Re-insert SD, then:
git clone https://github.com/lollonet/snapMULTI.git
./snapMULTI/scripts/prepare-sd.sh
# Insert SD in Pi, power on, wait ~10 min
```

### Any Linux (advanced)

```bash
git clone https://github.com/lollonet/snapMULTI.git && cd snapMULTI
sudo ./scripts/deploy.sh   # or: cp .env.example .env && docker compose up -d
```

## Add Speakers

Flash another SD → choose "Audio Player" → insert in any Pi. Auto-discovers the server.

Or install snapclient on any Linux: `sudo apt install snapclient`

## Updating

Reflash the SD card with the latest version — all config is auto-detected.

To preserve your music library index: `./scripts/backup-from-sd.sh` before flashing.
See [Usage Guide — Updating](docs/USAGE.md#updating) for advanced options.

## Documentation

| Guide | What's inside |
|-------|---------------|
| **[Quick Start](QUICKSTART.md)** | One-page install — zero to music in 5 minutes |
| [Installation](docs/INSTALL.md) | Complete step-by-step with troubleshooting |
| [Hardware](docs/HARDWARE.md) | Pi models, DAC HATs, network, tested combinations |
| [Usage & Ops](docs/USAGE.md) | Architecture, services, MPD, mDNS, updating |
| [Audio Sources](docs/SOURCES.md) | Source config, parameters, JSON-RPC API |
| [Changelog](CHANGELOG.md) | Version history |

## Contributing

PRs, bug reports, and "show your setup" posts are welcome — see [CONTRIBUTING.md](CONTRIBUTING.md).

For security issues, follow the private-disclosure flow in [SECURITY.md](SECURITY.md).

## Acknowledgments

Built on [Snapcast](https://github.com/badaix/snapcast) (Johannes Pohl), [go-librespot](https://github.com/devgianlu/go-librespot) (devgianlu), [shairport-sync](https://github.com/mikebrady/shairport-sync) (Mike Brady), [MPD](https://www.musicpd.org/), [myMPD](https://github.com/jcorporation/myMPD) (jcorporation), [tidal-connect](https://github.com/edgecrush3r/tidal-connect-docker) (edgecrush3r).
