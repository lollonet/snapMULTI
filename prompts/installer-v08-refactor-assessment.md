# snapMULTI v0.8 Installer Refactor Assessment Prompt

**How to invoke**: delegate to the `code-architecture-auditor` agent (read-only).
Spawn with the prompt body below and require the output structure listed at the end.

```text
You are assessing snapMULTI for a future v0.8 installer simplification track. Do not modify code.

Context:
The current installer is stable enough for launch. The goal is not to rewrite it before launch, but to identify a low-risk refactor roadmap that reduces duplicated install decisions, LOC, and future regression risk.

Read:
- scripts/prepare-sd.sh
- scripts/firstboot.sh
- scripts/deploy.sh
- client/common/scripts/setup.sh
- client/common/scripts/setup-zero2w.sh
- scripts/common/*.sh
- client/common/scripts/*.sh
- tests related to prepare-sd, firstboot, setup, deploy, Docker, overlayroot, systemd, mount music, release manifest, Pi Zero/native client

Deliver:
1. Map the current install flow for:
   - server
   - client Docker
   - both
   - Pi Zero 2 W native client

2. Identify duplicated decisions, especially:
   - INSTALL_TYPE / client-native / Pi Zero promotion
   - needs Docker
   - needs server stack
   - needs client stack
   - needs music source
   - readonly / overlayroot / fuse-overlayfs
   - systemd unit generation
   - copy/verify staging

3. Classify duplication:
   - harmless
   - drift-prone
   - bug-prone
   - too risky to touch now

4. Propose a v0.8 refactor roadmap:
   - PR 1: install-profile.sh + tests
   - PR 2: staging manifest for prepare-sd.sh
   - PR 3: firstboot phase/checkpoint wrapper
   - later: Docker/readonly helper consolidation
   - later: systemd unit generator
   - last: deep setup.sh split

5. Explicitly say what should NOT be touched before launch.

6. Estimate expected benefit:
   - LOC reduction
   - robustness gain
   - test coverage needed
   - required real-device reflash validation

7. For each proposed PR, list the SPECIFIC tests that must land before the
   refactor (block-the-refactor tests, not nice-to-have). Reference existing
   tests where possible; flag missing tests with the failure they would catch.

Constraints:
- No code changes.
- No speculative rewrite.
- Preserve reflash-first policy.
- Preserve current user-facing install flow.
- Treat firstboot as the canonical install path.
- Treat deploy.sh/setup.sh standalone mode as advanced/manual, not the primary product path.
- Real-device validation is mandatory for any future installer behavior change.

Output order: Findings → prioritized refactor roadmap → risks → recommended first PR.
```
