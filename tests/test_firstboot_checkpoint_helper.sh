#!/usr/bin/env bash
# Unit + static checks for run_checkpointed_phase in scripts/firstboot.sh
# (v0.8 PR5). Verifies the helper preserves the contract documented in
# its docstring and the migrated callsites (`deps`, `docker`) still
# emit the same checkpoint markers, log messages, and exit codes as
# the pre-PR5 inline pattern.
#
# Bash 3.2 compatible — no mapfile, no namerefs.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FIRSTBOOT="$SCRIPT_DIR/../scripts/firstboot.sh"

pass=0
fail=0

assert() {
    local cond="$1" desc="$2"
    if eval "$cond"; then
        echo "  PASS: $desc"
        pass=$((pass + 1))
    else
        echo "  FAIL: $desc"
        fail=$((fail + 1))
    fi
}

echo "=== Static checks ==="
assert '[[ -f "$FIRSTBOOT" ]]' "firstboot.sh exists"
assert 'bash -n "$FIRSTBOOT"' "firstboot.sh: bash -n clean"
assert 'grep -qE "^run_checkpointed_phase\\(\\) \\{" "$FIRSTBOOT"' \
       "run_checkpointed_phase() defined"

echo
echo "=== Migration: callsites use the helper ==="
# `deps` and `docker` migrated; their explicit `if checkpoint_reached` /
# `checkpoint_done` calls are gone, replaced by run_checkpointed_phase.
for cp in deps docker; do
    if grep -qE "run_checkpointed_phase \"${cp}\"" "$FIRSTBOOT"; then
        echo "  PASS: $cp uses run_checkpointed_phase"
        pass=$((pass + 1))
    else
        echo "  FAIL: $cp does NOT use run_checkpointed_phase"
        fail=$((fail + 1))
    fi
    # The legacy explicit pattern must be gone for the migrated checkpoint.
    if grep -qE "if checkpoint_reached \"${cp}\"; then" "$FIRSTBOOT"; then
        echo "  FAIL: legacy if checkpoint_reached \"$cp\" still present"
        fail=$((fail + 1))
    else
        echo "  PASS: legacy if checkpoint_reached \"$cp\" removed"
        pass=$((pass + 1))
    fi
done

echo
echo "=== Non-migration: 4 remaining checkpoints stay inline ==="
# fuse-overlayfs-switched, deploy, setup, music have multi-exit-path
# bodies or nested checkpoints — left inline by design (PR5 description).
for cp in fuse-overlayfs-switched deploy setup music; do
    if grep -qE "checkpoint_reached \"${cp}\"" "$FIRSTBOOT"; then
        echo "  PASS: $cp checkpoint still inline (not migrated, intentional)"
        pass=$((pass + 1))
    else
        echo "  FAIL: $cp checkpoint missing (must stay inline)"
        fail=$((fail + 1))
    fi
done

echo
echo "=== Inventory: every checkpoint name preserved ==="
expected="deploy
deps
docker
fuse-overlayfs-switched
music
setup"
actual=$(grep -oE 'checkpoint_(reached|done) "[a-z-]+"|run_checkpointed_phase "[a-z-]+"' "$FIRSTBOOT" | \
    sed -E 's|.*"([a-z-]+)"|\1|' | sort -u)
if [[ "$actual" == "$expected" ]]; then
    echo "  PASS: checkpoint name set is exactly {deploy, deps, docker, fuse-overlayfs-switched, music, setup}"
    pass=$((pass + 1))
else
    echo "  FAIL: checkpoint name set drifted"
    echo "  Expected:"; echo "$expected" | sed 's/^/    /'
    echo "  Actual:"; echo "$actual" | sed 's/^/    /'
    fail=$((fail + 1))
fi

echo
echo "=== Functional: extract helper + drive standalone ==="
# Extract run_checkpointed_phase + checkpoint_done + checkpoint_reached
# into a temp file. Skip the rest of firstboot (it reads install.conf,
# touches /boot/firmware, etc.).
EXTRACT=$(mktemp /tmp/snapmulti-checkpoint-XXXXXX.sh)
# shellcheck disable=SC2064
trap "rm -f '$EXTRACT'" EXIT

cat > "$EXTRACT" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
INSTALLER_STATE="${INSTALLER_STATE:?}"
# Minimal stub — the helper only needs log_info to emit the skip msg.
log_info() { printf '[INFO] %s\n' "$*"; }
EOF

awk '/^checkpoint_done\(\) \{/{f=1} f {print} f && /^\}/{f=0; print ""}' "$FIRSTBOOT" >> "$EXTRACT"
awk '/^checkpoint_reached\(\)/{print; print ""}' "$FIRSTBOOT" >> "$EXTRACT"
awk '/^run_checkpointed_phase\(\) \{/{f=1} f {print} f && /^\}/{f=0; print ""}' "$FIRSTBOOT" >> "$EXTRACT"

run_extract() {
    local state_dir="$1"; shift
    INSTALLER_STATE="$state_dir" bash "$EXTRACT" "$@"
}

# ── Case 1: checkpoint NOT reached + phase succeeds → marker written, rc=0
state=$(mktemp -d /tmp/snapmulti-state-XXXXXX)
out=$(INSTALLER_STATE="$state" bash -c "
set -euo pipefail
$(< "$EXTRACT")
_phase_ok() { return 0; }
run_checkpointed_phase 'unit-ok' 'skip msg' _phase_ok
" 2>&1)
rc=$?
if [[ -s "$state/.done-unit-ok" && "$rc" -eq 0 ]]; then
    echo "  PASS: success → checkpoint marker written (non-empty file), rc=0"
    pass=$((pass + 1))
else
    echo "  FAIL: success path (rc=$rc, marker exists: $([[ -e "$state/.done-unit-ok" ]] && echo yes || echo no))"
    fail=$((fail + 1))
fi
rm -rf "$state"

# ── Case 2: checkpoint NOT reached + phase explicitly returns non-zero
state=$(mktemp -d /tmp/snapmulti-state-XXXXXX)
rc=0
INSTALLER_STATE="$state" bash -c "
set -euo pipefail
$(< "$EXTRACT")
_phase_fail() { return 42; }
run_checkpointed_phase 'unit-fail' 'skip msg' _phase_fail
" >/dev/null 2>&1 || rc=$?
if [[ ! -e "$state/.done-unit-fail" && "$rc" -eq 42 ]]; then
    echo "  PASS: failure (explicit return) → no checkpoint marker, helper propagates exit code (42)"
    pass=$((pass + 1))
else
    echo "  FAIL: failure path explicit (rc=$rc, marker exists: $([[ -e "$state/.done-unit-fail" ]] && echo yes || echo no))"
    fail=$((fail + 1))
fi
rm -rf "$state"

# ── Case 2b: MULTI-COMMAND failure under set -e — the canonical bug
# the old `func || rc=\$?` wrapper hid. With errexit-suppression in the
# OR-list, `false` would not abort the function, `later_cmd` would run
# anyway, the function would return rc=0 (last command), and the helper
# would write the checkpoint marker for a half-executed phase. Without
# the OR list, `false` aborts the script BEFORE later_cmd runs, BEFORE
# checkpoint_done, and the marker stays absent.
state=$(mktemp -d /tmp/snapmulti-state-XXXXXX)
canary="$state/should-not-exist"
rc=0
INSTALLER_STATE="$state" bash -c "
set -euo pipefail
$(< "$EXTRACT")
_phase_multi_fail() {
    false
    touch '$canary'
}
run_checkpointed_phase 'unit-multi-fail' 'skip' _phase_multi_fail
" >/dev/null 2>&1 || rc=$?
if [[ ! -e "$state/.done-unit-multi-fail" && ! -e "$canary" && "$rc" -ne 0 ]]; then
    echo "  PASS: multi-command failure → set -e aborts on false, later cmd NOT run, no checkpoint marker"
    pass=$((pass + 1))
else
    echo "  FAIL: multi-command failure (rc=$rc, canary: $([[ -e "$canary" ]] && echo created || echo absent), marker: $([[ -e "$state/.done-unit-multi-fail" ]] && echo yes || echo no))"
    fail=$((fail + 1))
fi
rm -rf "$state"

# ── Case 2c: no command after the wrapper call executes when phase fails
# This is the operator-visible symptom of the old bug: if the wrapper
# swallowed the failure, the post-wrapper line would run on a broken
# system. Assert that the line AFTER run_checkpointed_phase never runs.
state=$(mktemp -d /tmp/snapmulti-state-XXXXXX)
post_canary="$state/post-wrapper-ran"
rc=0
INSTALLER_STATE="$state" bash -c "
set -euo pipefail
$(< "$EXTRACT")
_phase_fail2() { return 7; }
run_checkpointed_phase 'unit-post' 'skip' _phase_fail2
touch '$post_canary'
" >/dev/null 2>&1 || rc=$?
if [[ ! -e "$post_canary" && "$rc" -eq 7 ]]; then
    echo "  PASS: caller line AFTER wrapper call does NOT run when phase failed"
    pass=$((pass + 1))
else
    echo "  FAIL: post-wrapper line ran despite failure (rc=$rc, canary: $([[ -e "$post_canary" ]] && echo ran || echo skipped))"
    fail=$((fail + 1))
fi
rm -rf "$state"

# ── Case 3: checkpoint already reached → body NOT run, skip msg logged, rc=0
state=$(mktemp -d /tmp/snapmulti-state-XXXXXX)
echo "pre-existing" > "$state/.done-unit-skip"
side_effect="$state/side-effect.flag"
out=$(INSTALLER_STATE="$state" bash -c "
set -euo pipefail
$(< "$EXTRACT")
_phase_touch() { touch '$side_effect'; }
run_checkpointed_phase 'unit-skip' 'already done; skip' _phase_touch
" 2>&1)
rc=$?
if [[ "$rc" -eq 0 && ! -e "$side_effect" && "$out" == *"already done; skip"* ]]; then
    echo "  PASS: skip → body NOT invoked, log emitted, rc=0"
    pass=$((pass + 1))
else
    echo "  FAIL: skip path (rc=$rc, side-effect: $([[ -e "$side_effect" ]] && echo invoked || echo skipped))"
    fail=$((fail + 1))
fi
rm -rf "$state"

# ── Case 4: variable mutation propagates (no subshell)
state=$(mktemp -d /tmp/snapmulti-state-XXXXXX)
result=$(INSTALLER_STATE="$state" bash -c "
set -euo pipefail
$(< "$EXTRACT")
GLOBAL_FLAG=before
_phase_mutate() { GLOBAL_FLAG=after; }
run_checkpointed_phase 'unit-mutate' 'skip' _phase_mutate
printf '%s\n' \"\$GLOBAL_FLAG\"
")
if [[ "$result" == "after" ]]; then
    echo "  PASS: phase body mutation propagates to caller (no subshell)"
    pass=$((pass + 1))
else
    echo "  FAIL: variable mutation NOT propagated (got '$result', expected 'after')"
    fail=$((fail + 1))
fi
rm -rf "$state"

echo
echo "=== Summary ==="
echo "  Passed: $pass"
echo "  Failed: $fail"
(( fail == 0 ))
