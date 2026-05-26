---
id: DEC-INDEX
domain: decision-records
status: approved
source_of_truth: true
---

# Decision Records

Implementation decisions and their rationale — captured after the fact, often after a PR landed and a future contributor would ask "why this and not the obvious alternative?".

Distinct from [`docs/adr/`](../adr/ADR-INDEX.md):
- **ADR**: architectural choices made up-front (host networking, FIFO routing, read-only containers).
- **DEC**: implementation decisions discovered during work (which Docker driver to pre-configure, which SOUNDCARD string format works on headless Pis).

Both are accepted contracts — break them only with a new decision recorded here.

| ID | Decision | Status | Date |
|----|----------|--------|------|
| DEC-001 | [Pre-configure fuse-overlayfs before image pulls](DEC-001-fuse-overlayfs-pre-configure.md) | Accepted | 2026-04-24 |
| DEC-002 | [GPL-3.0 license (from MIT)](DEC-002-gpl3-license.md) | Accepted | 2026-04-24 |
| DEC-003 | [Reflash-only update strategy](DEC-003-reflash-only-updates.md) | Accepted | 2026-04-24 |
| DEC-004 | [Multi-Server Failover via discover-server.sh rewrite](DEC-004-multi-server-failover-design.md) | Accepted | 2026-04-28 |
| DEC-005 | [`_log` writes to stderr in scripts called via `$()`](DEC-005-log-stderr-convention.md) | Accepted | 2026-04-28 |
| DEC-006 | [Use `hw:CARD=NAME,DEV=0` for headless client SOUNDCARD](DEC-006-hw-card-soundcard-format.md) | Accepted | 2026-04-27 |
