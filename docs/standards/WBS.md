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

### 1.3 Spotify Connect
- [x] 1.3.1 Build Dockerfile.librespot
- [x] 1.3.2 Configure FIFO output
- [x] 1.3.3 Implement mDNS registration
- [x] 1.3.4 Add DEVICE_NAME sanitization

### 1.4 AirPlay Receiver
- [x] 1.4.1 Build Dockerfile.shairport-sync
- [x] 1.4.2 Configure shairport-sync.conf
- [x] 1.4.3 Implement mDNS registration
- [x] 1.4.4 Add DEVICE_NAME sanitization

### 1.5 Tidal Bridge (Optional)
- [x] 1.5.1 Build Dockerfile.tidal
- [x] 1.5.2 Implement tidal-bridge.py
- [x] 1.5.3 Configure as optional profile

## 2. Deployment

### 2.1 Zero-Touch Installation
- [x] 2.1.1 Create prepare-sd.sh for SD card setup
- [x] 2.1.2 Create firstboot.sh for Pi initialization
- [x] 2.1.3 Implement network wait logic
- [x] 2.1.4 Implement health check verification loop

### 2.2 Manual Deployment
- [x] 2.2.1 Create deploy.sh unified script
- [x] 2.2.2 Implement Docker installation
- [x] 2.2.3 Implement hardware detection
- [x] 2.2.4 Implement resource profile selection
- [x] 2.2.5 Implement Avahi installation
- [x] 2.2.6 Implement NFS detection for MPD_START_PERIOD

### 2.3 CI/CD Pipeline
- [x] 2.3.1 Set up build-push.yml for multi-arch builds
- [x] 2.3.2 Set up validate.yml for shellcheck
- [x] 2.3.3 Set up deploy.yml for SSH deployment
- [x] 2.3.4 Configure self-hosted runners (arm64, amd64)

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
- [ ] 5.1.4 status.sh script (#27)

### 5.2 Integrations
- [ ] 5.2.1 Home Assistant integration (#31)
- [ ] 5.2.2 Snapweb interface (#30)
- [ ] 5.2.3 Now-playing display support (#38)

### 5.3 Operations
- [ ] 5.3.1 Backup/restore scripts (#28)
- [ ] 5.3.2 Container vulnerability scanning (#36)
- [ ] 5.3.3 Pin package versions (#37)
- [ ] 5.3.4 Client setup guides (#34)

## Milestones

| Version | Milestone | Status |
|---------|-----------|--------|
| v0.1.0 | Initial release | Done |
| v0.1.1 | Deployment fixes, cover art | Done |
| v0.2.0 | Monitoring & Home Assistant | Planned |
| v1.0.0 | Production ready | Planned |
