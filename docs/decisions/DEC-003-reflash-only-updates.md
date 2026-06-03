---
type: decision
project: snapMULTI
date: 2026-04-24
status: accepted
pr: "#259"
supersedes: update.sh, Watchtower
tags: [decision, snapMULTI, updates, deployment]
---

# DEC-003: Reflash-only update strategy

## Context

snapMULTI initially offered three update paths:
1. `scripts/update.sh` — git pull + docker compose pull on writable systems
2. Watchtower — automatic Docker image updates (opt-in via `AUTO_UPDATE=true`)
3. Reflash — flash a new SD card with the latest version

Over time, the first two proved problematic on read-only Pi deployments.

## Decision

Reflash is the only supported update method. `update.sh` decommissioned (PR #259), Watchtower removed completely (v0.6.2).

## Rationale

### Why OTA doesn't work on overlayroot
- Pi Zero 2 W: 227 MB Docker images > 128 MB tmpfs. Cannot pull updates
- Any overlayroot Pi: images in tmpfs upper layer are lost on reboot
- `ro-mode disable && reboot` makes the Pi writable but requires SSH and a reboot — not zero-touch

### Why reflash is better than it sounds
- All config is auto-detected at install time (HAT, network, display, music source)
- Install takes ~10 minutes on Pi 4 (original measurement, against the v0.7-era install footprint; the current user-facing estimate documented in [INSTALL.md](../INSTALL.md) is ~15-20 minutes on Pi 4/5 — longer on Pi 3 or Pi Zero 2 W — and the reflash-as-update rationale still holds)
- MPD database can be backed up to boot partition and restored automatically — no library rescan
- The SD card IS the appliance. Reflash = factory reset + upgrade in one step

### Why Watchtower was removed
- Only worked on writable systems (minority of users)
- Silent image updates on an audio appliance = unexpected behavior changes
- No rollback mechanism — if a bad image ships, all Watchtower users break simultaneously
- Conflicted with the reflash-primary mental model

## What this means for users

- **Beginners**: Same experience. Flash SD, power on. To update: flash again
- **Advanced (writable server)**: `git pull && docker compose pull && docker compose up -d` still works — it's just not a supported script. Power users can manage Docker themselves
- **Future**: If OTA becomes feasible (e.g. A/B partition scheme), it would be a new feature, not a revival of update.sh

## Related

- [ADR-005](../adr/ADR-005.reflash-systemd-robustness.md) — reflash-only is one of three decisions consolidated there
- [DEC-001](DEC-001-fuse-overlayfs-pre-configure.md) — fuse-overlayfs decision directly affects why tmpfs-based updates fail
