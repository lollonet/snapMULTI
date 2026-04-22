#!/usr/bin/env bash
# Reconcile Docker storage driver with actual root filesystem state.
# Runs Before=docker.service so daemon.json is correct before Docker starts.
set -euo pipefail

command -v python3 &>/dev/null || exit 0
mkdir -p /etc/docker

if mount 2>/dev/null | grep -q ' on / type overlay'; then
    # Overlayroot active: Docker needs fuse-overlayfs
    if ! grep -q '"fuse-overlayfs"' /etc/docker/daemon.json 2>/dev/null; then
        python3 -c "
import json, os
path = '/etc/docker/daemon.json'
cfg = json.load(open(path)) if os.path.exists(path) else {}
cfg['storage-driver'] = 'fuse-overlayfs'
cfg.setdefault('live-restore', True)
cfg.setdefault('log-driver', 'json-file')
cfg.setdefault('log-opts', {'max-size': '10m', 'max-file': '3'})
with open(path, 'w') as f: json.dump(cfg, f, indent=2); f.write('\n')
" 2>/dev/null && logger -t docker-driver "Set fuse-overlayfs (overlayroot active)"
    fi
else
    # Writable root: remove forced storage-driver (Docker defaults to overlay2)
    if [[ -f /etc/docker/daemon.json ]] && grep -q '"storage-driver"' /etc/docker/daemon.json 2>/dev/null; then
        python3 -c "
import json
with open('/etc/docker/daemon.json') as f: cfg = json.load(f)
cfg.pop('storage-driver', None)
with open('/etc/docker/daemon.json', 'w') as f: json.dump(cfg, f, indent=2); f.write('\n')
" 2>/dev/null && logger -t docker-driver "Reset to default (writable root)"
    fi
fi
