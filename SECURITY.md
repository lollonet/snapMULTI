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
- **Filesystem**: Optional read-only root via overlayroot (protects SD card from corruption)
- **Secrets**: SMB credentials stored locally in `/etc/fstab`; NFS uses host-based auth
- **Updates**: Docker images signed and built in CI; Watchtower available for auto-updates

## Known Limitations

- Host networking exposes service ports to the local network (not just localhost)
- Tidal Connect container runs as root (proprietary binary requirement)
- SMB credentials on FAT32 boot partition are readable by anyone with physical SD card access
