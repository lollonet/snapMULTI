---
title: Work Breakdown Structure
status: stable
source_of_truth: true
---

# Work Breakdown Structure (WBS)

## 1. Core Audio System

### 1.1 Snapcast Server
- [x] 1.1.1 Build Dockerfile.snapserver (multi-stage, Alpine)
- [x] 1.1.2 Configure snapserver.conf (sources, mDNS, ports)
- [x] 1.1.3 Implement meta_mpd.py patch for metadata
- [x] 1.1.4 Set up health checks
- [x] 1.1.5 Configure resource limits

### 1.2 MPD Integration
- [x] 1.2.1 Build Dockerfile.mpd
- [x] 1.2.2 Configure mpd.conf (FIFO output, HTTP stream)
- [x] 1.2.3 Implement NFS mount detection
- [x] 1.2.4 Configure health checks with variable start_period
- [x] 1.2.5 Integrate myMPD web interface

### 1.3 Spotify Connect (go-librespot)
- [x] 1.3.1 Integrate upstream go-librespot image
- [x] 1.3.2 Configure pipe backend FIFO output
- [x] 1.3.3 Implement zeroconf device discovery
- [x] 1.3.4 Add DEVICE_NAME sanitization
- [x] 1.3.5 WebSocket API metadata integration (port 24879)

### 1.4 AirPlay Receiver
- [x] 1.4.1 Build Dockerfile.shairport-sync
- [x] 1.4.2 Configure shairport-sync.conf
- [x] 1.4.3 Implement mDNS registration
- [x] 1.4.4 Add DEVICE_NAME sanitization

### 1.5 Tidal Connect (ARM Only)
- [x] 1.5.1 Build Dockerfile.tidal (extends edgecrush3r base)
- [x] 1.5.2 Implement tidal-meta-bridge.sh (tmux TUI scraping)
- [x] 1.5.3 Configure ALSA routing (speex + FIFO)
- [x] 1.5.4 Add meta_tidal.py snapserver plugin

### 1.6 Metadata Service
- [x] 1.6.1 Build Dockerfile.metadata (Python 3.13, aiohttp)
- [x] 1.6.2 Implement multi-stream metadata polling
- [x] 1.6.3 Cover art chain (MPD → iTunes → MusicBrainz → Radio-Browser)
- [x] 1.6.4 WebSocket push to clients (port 8082)
- [x] 1.6.5 HTTP artwork server (port 8083)
- [x] 1.6.6 MusicBrainz rate limiter optimization

## 2. Deployment

### 2.1 Zero-Touch Installation
- [x] 2.1.1 Create prepare-sd.sh / prepare-sd.ps1 for SD card setup
- [x] 2.1.2 Create firstboot.sh for Pi initialization
- [x] 2.1.3 Implement network wait with 4-stage WiFi recovery
- [x] 2.1.4 Implement health check verification loop
- [x] 2.1.5 TUI progress display on HDMI console
- [x] 2.1.6 Unified installer (client/server/both menu)
- [x] 2.1.7 Headless client detection (HDMI vs no-display)

### 2.2 Manual Deployment
- [x] 2.2.1 Create deploy.sh unified script
- [x] 2.2.2 Implement Docker installation
- [x] 2.2.3 Implement hardware detection
- [x] 2.2.4 Implement resource profile selection
- [x] 2.2.5 Implement Avahi installation
- [x] 2.2.6 Implement NFS detection for MPD_START_PERIOD

### 2.3 CI/CD Pipeline
- [x] 2.3.1 Set up build-push.yml for multi-arch builds (5 images)
- [x] 2.3.2 Set up validate.yml for shellcheck + compose syntax
- [x] 2.3.3 Set up deploy.yml for SSH deployment
- [x] 2.3.4 Configure self-hosted ARM runners on Pi
- [x] 2.3.5 Set up build-test.yml for PR build validation
- [x] 2.3.6 Set up claude-code-review.yml for automated PR review
- [x] 2.3.7 Trivy container vulnerability scanning

## 3. Security

### 3.1 Container Hardening
- [x] 3.1.1 Enable read-only filesystems
- [x] 3.1.2 Drop all capabilities
- [x] 3.1.3 Enable no-new-privileges
- [x] 3.1.4 Configure tmpfs mounts

### 3.2 Input Validation
- [x] 3.2.1 Sanitize DEVICE_NAME in entrypoints
- [x] 3.2.2 Set FIFO permissions to 660

### 3.3 Secrets Management
- [x] 3.3.1 Use environment variables for sensitive config
- [x] 3.3.2 Exclude .env from git

## 4. Documentation

### 4.1 User Documentation
- [x] 4.1.1 Write README.md with quickstart
- [x] 4.1.2 Write docs/SOURCES.md for audio sources
- [x] 4.1.3 Write docs/USAGE.md for technical details
- [x] 4.1.4 Write docs/HARDWARE.md for requirements
- [x] 4.1.5 Maintain CHANGELOG.md

### 4.2 BassCodeBase Documentation
- [x] 4.2.1 Create VISION.md
- [x] 4.2.2 Create requirements (REQ-###.md)
- [x] 4.2.3 Create architecture (ARC-###.md)
- [x] 4.2.4 Create technology (TECH-###.md)
- [x] 4.2.5 Create WBS.md

## 5. Future Work (Open Issues)

### 5.1 Monitoring & Observability
- [ ] 5.1.1 Prometheus metrics (#35)
- [ ] 5.1.2 Failure notifications (#32)
- [ ] 5.1.3 Hardware watchdog (#29)
- [x] 5.1.4 status.sh script (#27) — v0.3.0

### 5.2 Integrations
- [ ] 5.2.1 Home Assistant integration (#31)
- [x] 5.2.2 Snapweb interface (#30) — v0.3.0
- [ ] 5.2.3 Now-playing display support (#38)

### 5.3 Operations
- [ ] 5.3.1 Backup/restore scripts (#28)
- [x] 5.3.2 Container vulnerability scanning (#36) — v0.3.0 (Trivy)
- [ ] 5.3.3 Pin package versions (#37)
- [ ] 5.3.4 Client setup guides (#34)

### 5.4 Audio Quality
- [ ] 5.4.1 Configurable sample rates (#77) — 48/96kHz support

## Milestones

| Version | Milestone | Status |
|---------|-----------|--------|
| v0.1.0 | Initial release — core audio sources | Done |
| v0.1.1 | Deployment fixes, cover art | Done |
| v0.2.0 | Centralized metadata service, Tidal metadata | Done |
| v0.3.0 | Security hardening, Snapweb, status script, Trivy | Done |
| v0.3.1 | MPD connection resilience | Done |
| v0.3.2 | First-boot reliability, per-image pull progress | Done |
| v0.3.3 | Performance optimizations (CPU -73% tidal, -79% metadata) | Done |
| v0.4.0 | Monorepo, single-branch CI, install hardening, shared modules | Done |
| v0.4.1 | EXIT trap fix, pull-images.sh rate limit detection | Done |
| v0.5.0 | Monitoring & observability (Prometheus, notifications) | Planned |
| v1.0.0 | Production ready, community launch | Planned |
