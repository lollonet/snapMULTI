#!/usr/bin/env bash
# Install Docker CE via official APT repository.
# Sourced by firstboot.sh and deploy.sh — single source of truth.
#
# Requires: curl, dpkg, apt-get (run as root)
# Side effects: adds Docker GPG key, APT source, installs docker-ce + compose plugin

install_docker_apt() {
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
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

    apt-get update -qq
    apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-compose-plugin
}
