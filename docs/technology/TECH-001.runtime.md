---
id: TECH-001
domain: technology
status: approved
source_of_truth: false
related: [ARC-002]
---

# TECH-001: Runtime Environment

## Container Runtime

- **Docker Engine**: 24.0+
- **Docker Compose**: v2 (compose plugin)
- **Base Image**: Alpine Linux 3.23

## Supported Architectures

| Architecture | Platform | Examples |
|--------------|----------|----------|
| linux/arm64 | ARM 64-bit | Raspberry Pi 4, Pi 5 |
| linux/amd64 | x86 64-bit | Intel/AMD servers, VMs |

## Host Requirements

### Minimum
- 1GB RAM (minimal profile)
- 2GB storage for images
- Network connectivity

### Recommended
- 2GB+ RAM (standard profile)
- 4GB+ RAM (performance profile)
- Gigabit Ethernet (for NFS mounts)

## Resource Profiles

| Profile | RAM Limit | CPU Limit | Use Case |
|---------|-----------|-----------|----------|
| minimal | 128MB/svc | 0.5 CPU | Pi Zero 2, Pi 3 |
| standard | 256MB/svc | 1.0 CPU | Pi 4 2GB |
| performance | 512MB/svc | 2.0 CPU | Pi 4 4GB+, Pi 5 |

## Network Requirements

- Host networking mode (required for mDNS)
- Avahi daemon on host (for service discovery)
- Ports: 1704, 1705, 1780, 4953, 6600, 8000, 8180

## Storage

| Path | Purpose | Size |
|------|---------|------|
| /opt/snapmulti | Installation | ~500MB |
| Docker images | Container images | ~1.5GB |
| /audio | FIFO pipes | <1MB |
| /data | Persistent state | ~100MB |
