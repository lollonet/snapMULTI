# Security Policy

## Supported Versions

| Version | Supported |
|---------|-----------|
| latest  | Yes       |
| < latest | No       |

## Reporting a Vulnerability

If you discover a security vulnerability in snapclient-pi, please report it responsibly:

1. **Do NOT open a public GitHub issue**
2. Use [GitHub Security Advisories](https://github.com/lollonet/snapMULTI/security/advisories/new)
3. Include: description, reproduction steps, affected versions, potential impact

We will acknowledge receipt within 48 hours and aim to release a fix within 7 days for critical issues.

## Scope

This policy covers:
- The snapclient-pi project (`lollonet/snapclient-pi`)
- Docker images published under `lollonet/snapclient-pi*`
- Install scripts (`setup.sh`, `discover-server.sh`, `display-detect.sh`)

For server-side issues, report to [snapMULTI](https://github.com/lollonet/snapMULTI/security/advisories/new).

## Security Model

snapclient-pi runs on home networks behind a firewall:

- **Containers**: `cap_drop: ALL`, `read_only: true`, `no-new-privileges`
- **Network**: Host networking for low-latency audio; not designed for public-facing deployment
- **Filesystem**: Optional read-only root via overlayroot
- **Audio**: ALSA device access via group membership (gid 29), not privileged mode
