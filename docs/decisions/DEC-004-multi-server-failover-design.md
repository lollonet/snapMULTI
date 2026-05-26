---
type: decision
project: snapMULTI
date: 2026-04-28
status: accepted
pr: "#285"
tags: [decision, snapMULTI, snapcast, failover, networkmanager, mdns]
---

# DEC-004: Multi-Server Failover via discover-server.sh Rewrite

## Context

snapMULTI supports multiple snapservers on the same LAN (issue #213). Each client has `SNAPSERVER_HOST` in its `.env` and a periodic `snapclient-discover.timer` that re-checks via mDNS. Pre-fix behavior:
- Timer fired every 5 min
- Picked the first IPv4 from `avahi-browse`
- Wrote `.env`
- Ran `docker compose restart`

When the user powered off `moniaserver` (the server several clients were bound to), clients should have failed over to `snapvideo`. They didn't. The audio went silent for 4 of 5 client devices, all while showing `Up X minutes (healthy)` from Docker's perspective.

## Problem

Five distinct bugs, each masking the next, conspired to make the timer a no-op:

1. `docker compose restart` does not re-read `.env` — the IP update was effectively discarded
2. Even with #1 fixed, every timer fire would potentially swap servers based on `avahi-browse` ordering — flapping
3. Avahi has 1-3 min cache for dead servers; could re-pick the dead one and exit "unchanged"
4. `_log()` in the script writes to stdout; functions called via `$()` capture stdout, polluting the IP regex match — script always reported "no servers found"
5. After a recreate failure mid-`up -d`, container can exist in `Created` state with correct config but never started; next cycle sees no drift and exits

## Decision

Rewrite `discover-server.sh` with four interlocking checks, in order:

1. **Reconcile drift** — `docker inspect snapclient .Config.Env` SNAPSERVER_HOST vs `.env`. If differ, run `up -d` (handles devices left in env-drift state by the legacy `restart` bug).
2. **Reconcile runtime** — `docker inspect .State.Running`. If false, run `up -d` (handles transient recreate failures).
3. **TCP health probe** — `bash /dev/tcp/$current/1704` with 3s timeout. If alive, exit "no scan" (avoids flapping when current is healthy).
4. **mDNS fallback** — enumerate ALL IPv4 servers, prefer one different from current (handles stale Avahi cache).

Plus:
- Use `docker compose up -d`, never `restart`, for any container reconfig.
- `_log` writes to stderr, never stdout (so `$()` captures don't get polluted).
- Tighten timer from `OnUnitActiveSec=5min` to `60s` (failover within ~1 min vs 7 min worst-case).
- Tag every log line with `[discover]` for `journalctl` greppability; emit mDNS result list for diagnostic visibility.

## Why

- All five bugs need to be addressed; fixing only some leaves silent failure modes
- The order matters: check container state before TCP, because a stuck container may show .env-IP alive but be on the wrong env
- `up -d` is idempotent — it recreates only when effective config differs, so calling it on every cycle is cheap (~50ms when no-op)
- 60s timer interval is monotonic (NTP-immune via systemd) and cheap to fire
- Logging on stderr preserves journalctl visibility while freeing stdout for shell function returns

## Consequences

- Devices stuck after the legacy `restart` bug auto-heal within 60s of the timer being deployed
- True multi-server failover when the current server dies, recovery in 60-72s
- No flapping when both servers alive (TCP probe short-circuits the scan)
- Robust against transient docker glitches (Container `Created` state caught and retried)
- snapcast 0.35.0 unchanged (this is all on the host side)

## Alternatives Considered

- **Multicast subscription via avahi-publish-service** — would require server-side changes too, larger blast radius
- **systemd `OnFailure=` triggered re-discovery** — more reactive but more complex; 60s polling is good enough
- **Bake server priority into `.env`** — couples deploy to topology, defeats mDNS auto-discovery
- **Pin to first-seen server forever** — fragile if hardware changes IPs

## Files Changed

- `client/common/scripts/discover-server.sh` — full rewrite
- `client/common/scripts/setup.sh` — timer interval 5min → 60s

## Verification

Live tested on 4 client devices via volatile deploy:
- moniaclient (Pi 3, drift state) — auto-recovered to moniaserver in one cycle
- snapdigi (Pi 4, drift state) — auto-recovered to snapvideo
- pizero (Pi Zero 2W, drift state) — auto-recovered via natural timer fire
- piotto (Pi 4, drift state) — auto-recovered

End-to-end recovery time: 60-72 seconds (60s timer + ~10s recreate).

## Related

- [DEC-005](DEC-005-log-stderr-convention.md) — stderr convention discovered while implementing this
