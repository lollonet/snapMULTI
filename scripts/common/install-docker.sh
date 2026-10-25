#!/usr/bin/env bash
# Install Docker CE via official APT repository.
# Sourced by firstboot.sh and deploy.sh — single source of truth.
#
# Requires: curl, dpkg, apt-get (run as root)
# Side effects: adds Docker GPG key, APT source, installs docker-ce + compose plugin

# Map a Debian codename to the Docker CE repo suite that serves it.
# Docker publishes one suite per Debian release; a codename newer than
# the ones listed here (testing/sid) uses the newest published suite.
docker_repo_codename() {
    case "$1" in
        bullseye|bookworm|trixie) echo "$1" ;;
        *) echo "trixie" ;;
    esac
}

# Add Docker apt repo and GPG key. Idempotent: skips if already configured.
# Does NOT run apt-get update — caller decides when to refresh.
setup_docker_repo() {
    if [[ -f /etc/apt/sources.list.d/docker.list && -f /etc/apt/keyrings/docker.asc ]]; then
        return 0
    fi

    install -m 0755 -d /etc/apt/keyrings
    if ! curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc; then
        return 1
    fi
    chmod a+r /etc/apt/keyrings/docker.asc

    local arch docker_codename
    arch=$(dpkg --print-architecture)
    docker_codename=$(docker_repo_codename "$(. /etc/os-release && echo "$VERSION_CODENAME")")

    echo "deb [arch=$arch signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian $docker_codename stable" \
        > /etc/apt/sources.list.d/docker.list
}

# Bounded wait for the dpkg frontend lock (unattended-upgrades, apt-daily,
# cloud-init's own package runs). Reuses install-deps.sh's helper when the
# caller sourced it; this file is also sourced on its own by deploy.sh and
# client setup.sh, so keep a local fallback with the same 5-minute cap.
_docker_apt_wait_lock() {
    if declare -F _wait_for_apt_lock >/dev/null 2>&1; then
        _wait_for_apt_lock
        return 0
    fi
    command -v fuser >/dev/null 2>&1 || return 0
    local deadline=$(( SECONDS + 300 ))
    while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; do
        (( SECONDS >= deadline )) && return 0
        sleep 5
    done
}

_docker_apt_msg() {
    local level="$1"; shift
    if [[ "$level" == "error" ]] && declare -F log_error >/dev/null 2>&1; then
        log_error "$*"
    elif declare -F log_warn >/dev/null 2>&1; then
        log_warn "$*"
    elif [[ "$level" == "error" ]]; then
        echo "[ERROR] [docker] $*" >&2
    else
        echo "[WARN] [docker] $*" >&2
    fi
}

# _docker_apt_run DESC CMD...
#
# Runs an apt command up to DOCKER_APT_ATTEMPTS times (default 3). Before
# each attempt waits for the dpkg lock; between attempts runs the same
# dpkg/apt recovery as install-deps.sh's _apt_install_with_recovery and
# backs off. Command output goes to $UNIFIED_LOG (the install log) so the
# real apt error is there for the diagnostic bundle; without an install
# log the tail of a failed attempt is printed to stderr instead.
_docker_apt_run() {
    local desc="$1"; shift
    local attempts="${DOCKER_APT_ATTEMPTS:-3}" attempt out rc
    for (( attempt = 1; attempt <= attempts; attempt++ )); do
        _docker_apt_wait_lock
        rc=0
        out=$("$@" 2>&1) || rc=$?
        if [[ -n "${UNIFIED_LOG:-}" ]]; then
            { printf '%s\n' "--- $desc (attempt $attempt/$attempts, rc=$rc) ---" "$out"; } \
                >> "$UNIFIED_LOG" 2>/dev/null || true
        fi
        (( rc == 0 )) && return 0
        _docker_apt_msg warn "$desc failed (attempt $attempt/$attempts, rc=$rc)"
        if [[ -z "${UNIFIED_LOG:-}" ]]; then
            printf '%s\n' "$out" | tail -n 20 >&2
        fi
        (( attempt < attempts )) || break
        dpkg --configure -a >> "${UNIFIED_LOG:-/dev/null}" 2>&1 || true
        apt-get -f install -y >> "${UNIFIED_LOG:-/dev/null}" 2>&1 || true
        sleep $(( attempt * ${DOCKER_APT_BACKOFF:-10} ))
    done
    _docker_apt_msg error "$desc failed after $attempts attempts${UNIFIED_LOG:+ — apt output in $UNIFIED_LOG}"
    return 1
}

install_docker_apt() {
    if ! setup_docker_repo; then
        return 1
    fi

    # Skip update when caller already refreshed metadata after adding the repo
    # (firstboot consolidates Debian + Docker into one apt-get update).
    if [[ "${SKIP_APT_UPDATE:-false}" != "true" ]]; then
        _docker_apt_run "apt-get update (Docker repo)" apt-get update || return 1
    fi
    _docker_apt_run "apt-get install docker-ce" \
        apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
}
