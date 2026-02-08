---
title: Vision — snapMULTI
status: stable
source_of_truth: true
anchors:
  - VISION-001
  - VISION-002
  - VISION-003
---

# Vision

## Why

Deliver synchronized multiroom audio to any room in your home using commodity hardware. Turn a Raspberry Pi into a dedicated audio appliance that streams from Spotify, AirPlay, MPD, or any TCP source—with perfect sync across all speakers.

## Who

- **Home users**: Want whole-home audio without expensive proprietary systems
- **Hobbyists**: Raspberry Pi enthusiasts building DIY audio setups
- **Self-hosters**: Users who want control over their music infrastructure

## Outcomes (KPIs)

- Zero-touch installation: Flash SD, plug in, play music within 10 minutes
- Sync accuracy: <10ms audio drift across all connected clients
- Five audio sources working out of the box (MPD, Spotify, AirPlay, TCP, Tidal)
- Container health: All 5 services healthy within 5 minutes of boot
- mDNS discovery: Clients auto-discover server without manual IP configuration

## Non-Goals

- Replace commercial solutions (Sonos, HEOS) for non-technical users
- Provide room EQ or advanced DSP processing
- Support video/AV sync (audio-only system)
- Multi-tenant or cloud-hosted deployments

## Constraints

- Host networking required for mDNS/Avahi service discovery
- Docker and Docker Compose as the only deployment method
- Audio format fixed at 44100:16:2 (CD quality) across all sources
- ARM64 (Raspberry Pi 4/5) and AMD64 (x86_64) architectures only
- Single-server topology (no clustering)

## Milestones

- **VISION-001**: Zero-touch deployment via SD card preparation
- **VISION-002**: All five audio sources functional with mDNS discovery
- **VISION-003**: Production-ready with security hardening and resource profiles
