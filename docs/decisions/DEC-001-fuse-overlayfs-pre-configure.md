---
type: decision
project: snapMULTI
date: 2026-04-24
status: accepted
pr: "#271"
tags: [decision, snapMULTI, docker, overlayroot]
---

# DEC-001: Pre-configure fuse-overlayfs before image pulls

## Context

Docker supports two storage drivers on Raspberry Pi: `overlay2` (kernel-native, fast) and `fuse-overlayfs` (userspace, ~20-40% slower IO). When overlayroot is active, only fuse-overlayfs works — kernel overlay2 cannot layer on an overlayfs root.

Three prior PRs deliberately moved the driver decision away from install-time intent (`ENABLE_READONLY`) to boot-time filesystem detection:

- **PR #245**: Removed `ENABLE_READONLY` gate — writable systems were getting fuse-overlayfs overhead for no reason
- **Commit 38cf565**: Moved driver decision to boot time — if overlayroot fails, Docker shouldn't be on the wrong driver
- **PR #268**: Refined — daemon.json created without storage-driver, reconciler sets it at boot

## Problem

On `both` mode (server+client) with readonly enabled:
1. First boot: root is writable ext4, Docker uses overlay2, pulls ~1.5 GB of images
2. Reboot: overlayroot activates, `docker-driver-reconcile.sh` switches to fuse-overlayfs
3. Docker cannot see overlay2 images — different driver, different directory structure
4. Docker re-pulls all images into tmpfs upper layer
5. tmpfs fills to 95%, client images fail with "no space left on device"

Confirmed on snapvideo: 1.7 GB in `/media/root-rw/overlay/var/lib/docker/fuse-overlayfs/`, lower layer at `/media/root-ro/var/lib/docker/` had zero image storage.

## Decision

In `firstboot.sh`, after Docker install but before any image pulls, switch to fuse-overlayfs when `ENABLE_READONLY=true`.

This is NOT "gating on intent in general" (which PR #245 correctly rejected). It is "preparing the next boot mode" — the script knows overlayroot will activate after reboot, and the images must be stored with the driver that will be active then.

`docker-driver-reconcile.sh` remains as boot-time safety net for edge cases (overlayroot fails to activate → reconciler reverts to overlay2).

## Tradeoff

- **Accept**: ~20-40% slower image pull during first boot (one-time cost, extra ~5 minutes)
- **Avoid**: 1.5 GB re-pull into tmpfs on every reboot (permanent, breaks client installs)
- **Edge case**: if overlayroot fails to activate, fuse-overlayfs images become invisible on overlay2 — same class of problem but in the failure path, not the happy path. Reconciler handles this.

## Alternatives Considered

- **Pull with overlay2, convert after**: Requires pulling twice. Slower than the accepted approach
- **Bind-mount /var/lib/docker at boot**: Already tried, complicated boot early-stage too much
- **Bake step (rsync to lower layer)**: Only works when overlayroot is already active, no-op on first boot

## Files Changed

- `scripts/firstboot.sh` — pre-configure block after Docker install
- `scripts/deploy.sh` — preserve fuse-overlayfs if already configured
- `client/common/scripts/setup.sh` — same preservation
- `scripts/boot-tune.sh` — fix tmpfs mount point detection (related but separate bug)
