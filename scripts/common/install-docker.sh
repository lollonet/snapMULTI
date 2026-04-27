#!/usr/bin/env bash
# Install Docker CE via official APT repository.
# Sourced by firstboot.sh and deploy.sh — single source of truth.
#
# Requires: curl, dpkg, apt-get (run as root)
# Side effects: adds Docker GPG key, APT source, installs docker-ce + compose plugin

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

    local arch version_codename docker_codename
    arch=$(dpkg --print-architecture)
    version_codename=$(. /etc/os-release && echo "$VERSION_CODENAME")

    # Docker doesn't support all Debian versions — fallback to bookworm
    case "$version_codename" in
        bullseye|bookworm) docker_codename="$version_codename" ;;
        *) docker_codename="bookworm" ;;
    esac

    echo "deb [arch=$arch signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian $docker_codename stable" \
        > /etc/apt/sources.list.d/docker.list
}

install_docker_apt() {
    setup_docker_repo

    # Skip update when caller already refreshed metadata after adding the repo
    # (firstboot consolidates Debian + Docker into one apt-get update).
    if [[ "${SKIP_APT_UPDATE:-false}" != "true" ]]; then
        apt-get update -qq
    fi
    apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-compose-plugin
}
