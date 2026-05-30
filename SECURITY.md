# Security Policy

## Supported Versions

| Version | Supported |
|---------|-----------|
| latest  | Yes       |
| < latest | No       |

## Reporting a Vulnerability

If you discover a security vulnerability in snapMULTI, please report it responsibly:

1. **Do NOT open a public GitHub issue**
2. Use [GitHub Security Advisories](https://github.com/lollonet/snapMULTI/security/advisories/new)
3. Include: description, reproduction steps, affected versions, potential impact

We will acknowledge receipt within 48 hours and aim to release a fix within 7 days for critical issues.

## Scope

This policy covers:
- The snapMULTI server (`lollonet/snapMULTI`)
- The snapclient (`lollonet/snapclient-pi`)
- Docker images published under `lollonet/snapmulti-*`
- Install scripts (`prepare-sd.sh`, `firstboot.sh`, `deploy.sh`, `setup.sh`)

## Security Model

snapMULTI is designed for **home/prosumer networks** behind a firewall:

- **Containers**: `cap_drop: ALL` with minimal capabilities, `read_only: true`, `no-new-privileges`
- **Network**: Host networking for low-latency audio; not designed for public-facing deployment
- **Filesystem**: Read-only root via overlayroot is enabled by default on Pi installs (protects SD card from corruption) and can be disabled for maintenance.
- **Secrets**: SMB credentials stored in `/etc/snapmulti-smb-credentials` (mode 600), referenced by a systemd `.mount` unit in `/etc/systemd/system/`; NFS uses host-based auth
- **Updates**: Docker images built in CI on GitHub Actions, published multi-arch (amd64 + arm64) to Docker Hub. Image signing (cosign / sigstore) is not yet implemented — track via SECURITY advisories if integrity attestation is required for your deployment. Full upgrades use the reflash path ([DEC-003](docs/decisions/DEC-003-reflash-only-updates.md))

## Privacy and Telemetry

snapMULTI itself does not collect telemetry and does not depend on a hosted snapMULTI cloud service or snapMULTI account. Control, status, metadata and playback APIs run on the local network.

External traffic can still happen through normal dependencies and integrations: package/image downloads during install or update, Docker Hub pulls, GitHub release downloads, Spotify/Tidal/AirPlay provider traffic, and metadata/artwork lookups. Those services are outside the snapMULTI control plane.

## Known Limitations

- Host networking exposes service ports to the local network (not just localhost)
- Tidal Connect container runs as root (proprietary binary requirement)
- SMB credentials on FAT32 boot partition are readable by anyone with physical SD card access
