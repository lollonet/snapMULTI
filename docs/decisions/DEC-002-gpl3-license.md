---
type: decision
project: snapMULTI
date: 2026-04-24
status: accepted
tags: [decision, snapMULTI, license, legal]
---

# DEC-002: GPL-3.0 license (from MIT)

## Context

snapMULTI was initially released under MIT. The project orchestrates several GPL-licensed components (Snapcast GPLv3, MPD GPLv2+, myMPD GPLv3) via Docker containers without linking or modifying their code. MIT was technically valid — orchestration scripts don't trigger GPL copyleft.

## Decision

Switch from MIT to GPL-3.0.

## Rationale

- **Protection from commercial appropriation**: MIT allows anyone to take the code, close it, and sell it. The owner explicitly does not want this
- **Alignment with ecosystem**: Snapcast (GPLv3), MPD (GPLv2+), myMPD (GPLv3) are all copyleft. GPL-3.0 is the natural fit
- **No downside for the community**: users can still use, modify, and distribute. They just can't close the source
- **Contributor clarity**: GPL-3.0 sets clear expectations for anyone contributing

## What this does NOT affect

- Using snapMULTI at home or in a business (not distribution)
- Forking and modifying (must keep GPL-3.0)
- Commercial use where source is provided (GPL allows this)
- The Docker images (containers are separate works, not derivatives of the scripts)

## Alternatives Considered

- **AGPL-3.0**: Too aggressive — snapMULTI has no network service interface where AGPL's server clause would matter
- **MIT with Commons Clause**: Confusing, not OSI-approved
- **Keep MIT**: Does not protect against the specific concern (commercial appropriation)
