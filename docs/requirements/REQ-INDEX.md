---
id: REQ-INDEX
domain: requirements
status: approved
source_of_truth: true
related: []
acceptance:
  - "The file defines the index and REQ-### naming."
  - "Front matter is valid per spec_lint (required fields present)."
---

# Index of Requirements: REQ-###

## Functional Requirements

### Audio Sources
- **REQ-001**: MPD local music playback — *approved*
- **REQ-002**: Spotify Connect integration — *approved*
- **REQ-003**: AirPlay receiver — *approved*
- **REQ-004**: TCP audio input — *approved*
- **REQ-005**: Tidal streaming (optional profile) — *approved*
- **REQ-006**: Configurable audio sample rates ([#77](https://github.com/lollonet/snapMULTI/issues/77)) — *proposed*

### Streaming & Sync
- **REQ-010**: Snapcast synchronized playback — *approved*
- **REQ-011**: Client auto-discovery via mDNS — *approved*
- **REQ-012**: Multi-client group management — *approved*

### Deployment
- **REQ-020**: Zero-touch SD card installation — *approved*
- **REQ-021**: Deploy script for any Linux host — *approved*
- **REQ-022**: Hardware auto-detection and resource profiles — *approved*

### Operations
- **REQ-030**: Container health monitoring — *approved*
- **REQ-031**: Graceful service recovery — *approved*
- **REQ-032**: Log management — *approved*
- **REQ-033**: Prometheus metrics ([#35](https://github.com/lollonet/snapMULTI/issues/35)) — *proposed*
- **REQ-034**: Failure notifications ([#32](https://github.com/lollonet/snapMULTI/issues/32)) — *proposed*
- **REQ-035**: Hardware watchdog ([#29](https://github.com/lollonet/snapMULTI/issues/29)) — *proposed*

### Integrations
- **REQ-040**: Home Assistant integration ([#31](https://github.com/lollonet/snapMULTI/issues/31)) — *proposed*
- **REQ-041**: Now-playing display support ([#38](https://github.com/lollonet/snapMULTI/issues/38)) — *proposed*

### Data Management
- **REQ-050**: Backup and restore ([#28](https://github.com/lollonet/snapMULTI/issues/28)) — *proposed*

## Non-Functional Requirements

- **REQ-100**: Security hardening (read-only containers, cap_drop) — *approved*
- **REQ-101**: Resource constraints (memory limits, CPU quotas) — *approved*
- **REQ-102**: Network requirements (host mode, mDNS) — *approved*

## Status Legend

| Status | Meaning |
|--------|---------|
| approved | Implemented and tested |
| draft | Under development |
| proposed | Not yet started |
