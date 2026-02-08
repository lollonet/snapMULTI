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
- **REQ-001**: MPD local music playback
- **REQ-002**: Spotify Connect integration
- **REQ-003**: AirPlay receiver
- **REQ-004**: TCP audio input
- **REQ-005**: Tidal streaming (optional profile)

### Streaming & Sync
- **REQ-010**: Snapcast synchronized playback
- **REQ-011**: Client auto-discovery via mDNS
- **REQ-012**: Multi-client group management

### Deployment
- **REQ-020**: Zero-touch SD card installation
- **REQ-021**: Deploy script for any Linux host
- **REQ-022**: Hardware auto-detection and resource profiles

### Operations
- **REQ-030**: Container health monitoring
- **REQ-031**: Graceful service recovery
- **REQ-032**: Log management

## Non-Functional Requirements

- **REQ-100**: Security hardening (read-only containers, cap_drop)
- **REQ-101**: Resource constraints (memory limits, CPU quotas)
- **REQ-102**: Network requirements (host mode, mDNS)

## Status Legend

| Status | Meaning |
|--------|---------|
| approved | Implemented and tested |
| draft | Under development |
| proposed | Not yet started |
