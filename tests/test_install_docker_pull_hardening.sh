#!/usr/bin/env bash
# install-docker.sh: apt retry / dpkg-lock wait / errors in the install log.
# pull-images.sh: rate-limit detection matches the registry's wording, not
# any "429" substring (layer digests and byte counts contain it).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DOCKER_SH="$SCRIPT_DIR/../scripts/common/install-docker.sh"
PULL_IMAGES_SH="$SCRIPT_DIR/../scripts/common/pull-images.sh"

pass=0
fail=0
ok()  { echo "  PASS: $1"; pass=$((pass + 1)); }
bad() { echo "  FAIL: $1"; fail=$((fail + 1)); }

TMPD=$(mktemp -d)
trap 'rm -rf "$TMPD"' EXIT

echo "=== install-docker.sh: install_docker_apt retries ==="

# Each scenario runs in a subshell with apt-get/dpkg/fuser/sleep stubbed
# as functions (they shadow the real binaries) and setup_docker_repo
# stubbed out (no network, no /etc writes).
#   $1 = number of apt-get install failures before success
#   $2 = number of fuser "lock held" answers before the lock frees
run_install() {
    local install_failures="$1" lock_busy="$2"
    rm -f "$TMPD"/state.* "$TMPD/install.log"
    (
        set -euo pipefail
        export UNIFIED_LOG="$TMPD/install.log"
        export DOCKER_APT_BACKOFF=0
        # shellcheck source=../scripts/common/install-docker.sh
        source "$INSTALL_DOCKER_SH"
        setup_docker_repo() { return 0; }
        sleep() { :; }
        fuser() {
            local n; n=$(cat "$TMPD/state.fuser" 2>/dev/null || echo 0)
            echo $((n + 1)) > "$TMPD/state.fuser"
            (( n < lock_busy ))
        }
        dpkg() { echo "dpkg $*" >> "$TMPD/state.calls"; }
        apt-get() {
            echo "apt-get $*" >> "$TMPD/state.calls"
            if [[ "$1" == "install" ]]; then
                local n; n=$(cat "$TMPD/state.inst" 2>/dev/null || echo 0)
                echo $((n + 1)) > "$TMPD/state.inst"
                if (( n < install_failures )); then
                    echo "E: Failed to fetch https://download.docker.com/linux/debian/dists/trixie/pool/stable/containerd.io.deb  Connection timed out"
                    return 100
                fi
            fi
            echo "apt ok: $*"
        }
        install_docker_apt
    ) >"$TMPD/stdout" 2>"$TMPD/stderr"
}

if run_install 0 0; then ok "clean install succeeds"; else bad "clean install failed"; fi
grep -qF 'apt-get update' "$TMPD/state.calls" && ok "apt-get update still runs by default" || bad "apt-get update not run"
if grep -qE -- '-qq' "$TMPD/state.calls"; then bad "apt output still silenced with -qq"; else ok "no -qq: apt output reaches the install log"; fi

if run_install 2 0; then ok "transient install failure (2x) is retried and succeeds"; else bad "transient failure not retried"; fi
[[ "$(cat "$TMPD/state.inst")" == "3" ]] && ok "install attempted 3 times" || bad "install attempts: $(cat "$TMPD/state.inst")"
grep -qF 'dpkg --configure -a' "$TMPD/state.calls" && ok "dpkg recovery runs between attempts" || bad "no dpkg recovery between attempts"
grep -qF 'Connection timed out' "$TMPD/install.log" && ok "the real apt error lands in the install log" || bad "apt error missing from install log"

if run_install 5 0; then bad "persistent failure reported success"; else ok "persistent failure returns non-zero"; fi
[[ "$(cat "$TMPD/state.inst")" == "3" ]] && ok "gives up after 3 attempts" || bad "attempts on persistent failure: $(cat "$TMPD/state.inst")"
grep -qF 'failed after 3 attempts' "$TMPD/stderr" && ok "final failure is reported" || bad "final failure not reported"

if run_install 0 3; then ok "install proceeds once the dpkg lock frees"; else bad "lock wait broke the install"; fi
[[ "$(cat "$TMPD/state.fuser")" -ge 4 ]] && ok "waited on the dpkg frontend lock before apt" || bad "did not wait on the dpkg lock"

# SKIP_APT_UPDATE contract (firstboot already refreshed metadata).
rm -f "$TMPD"/state.*
(
    export SKIP_APT_UPDATE=true UNIFIED_LOG="$TMPD/install.log"
    # shellcheck source=../scripts/common/install-docker.sh
    source "$INSTALL_DOCKER_SH"
    setup_docker_repo() { return 0; }
    fuser() { return 1; }
    apt-get() { echo "apt-get $*" >> "$TMPD/state.calls"; }
    install_docker_apt
) >/dev/null 2>&1
if grep -qF 'apt-get update' "$TMPD/state.calls"; then bad "SKIP_APT_UPDATE=true still ran apt-get update"; else ok "SKIP_APT_UPDATE=true skips apt-get update"; fi

echo
echo "=== pull-images.sh: rate-limit detection ==="
eval "$(sed -n '/^_pull_rate_limited()/,/^}/p' "$PULL_IMAGES_SH")"
check_rl() {
    local want="$1" desc="$2" text="$3"
    printf '%s\n' "$text" > "$TMPD/pull.log"
    local got=no
    _pull_rate_limited "$TMPD/pull.log" && got=yes
    [[ "$got" == "$want" ]] && ok "$desc" || bad "$desc (got rate_limited=$got)"
}
check_rl yes "Docker Hub toomanyrequests" \
    'Error response from daemon: toomanyrequests: You have reached your pull rate limit. You may increase the limit by authenticating and upgrading: https://www.docker.com/increase-rate-limit'
check_rl yes "HTTP 429 Too Many Requests" \
    'failed to copy: httpReadSeeker: failed open: unexpected status code https://registry-1.docker.io/v2/...: 429 Too Many Requests'
check_rl yes "generic 'rate limit' wording" 'error pulling image: rate limit exceeded'
check_rl no "layer digest containing 429 is not a rate limit" \
    $'a4291b3c9d2e: Pulling fs layer\nsha256:9f8e7d429aa1 Download complete\nunexpected EOF'
check_rl no "byte count containing 429 is not a rate limit" \
    $'d1e2f3a4b5c6: Downloading [=====>     ]  14.29MB/42.9MB\nread tcp 192.168.1.42:51234->104.16.98.215:443: read: connection reset by peer'
check_rl no "plain network failure is not a rate limit" 'Get "https://registry-1.docker.io/v2/": dial tcp: lookup registry-1.docker.io: Temporary failure in name resolution'
if grep -qE 'grep -qi "too many requests\\\|rate limit\\\|429"' "$PULL_IMAGES_SH"; then
    bad "bare 429 substring match still present"
else
    ok "bare 429 substring match removed"
fi
grep -qF 'if _pull_rate_limited "$log"; then' "$PULL_IMAGES_SH" && ok "_pull_one uses _pull_rate_limited" || bad "_pull_one does not use _pull_rate_limited"

echo
echo "Results: $pass passed, $fail failed"
exit $(( fail > 0 ? 1 : 0 ))
