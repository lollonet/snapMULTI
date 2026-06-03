# prepare-sd.ps1 — Unified SD card preparation for snapMULTI (Windows).
#
# PowerShell equivalent of prepare-sd.sh. Asks what to install, copies
# the right files to the boot partition, and patches cloud-init so the
# Pi auto-installs everything on first boot.
#
# Usage:
#   .\scripts\prepare-sd.ps1                 # auto-detect boot partition
#   .\scripts\prepare-sd.ps1 -Boot E:\       # specify drive letter
#
# Requires: PowerShell 5.1+ (ships with Windows 10/11)
#Requires -Version 5.1

[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$Boot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Explicit UTF-8 (no BOM) for all file writes — PS 5.1 (.NET Framework)
# defaults to UTF-16 with WriteAllText, which corrupts boot partition files.
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectDir = Split-Path -Parent $ScriptDir
$ClientDir = Join-Path $ProjectDir 'client'

# ── Read release manifest ─────────────────────────────────────────
# Resolved from $ScriptDir (script-anchored) so the manifest is found
# regardless of the cwd the operator invoked us from. Missing manifest
# falls back to empty strings + the legacy 'latest' IMAGE_TAG default.
$ManifestPath = Join-Path $ProjectDir 'release-manifest.json'
$ManifestRelease = ''
$ManifestImageSet = ''
if (Test-Path $ManifestPath) {
    try {
        $manifest = Get-Content -Raw -Path $ManifestPath | ConvertFrom-Json
        if ($manifest.PSObject.Properties.Name -contains 'snapmulti_release') {
            $ManifestRelease = [string]$manifest.snapmulti_release
        }
        if ($manifest.PSObject.Properties.Name -contains 'image_set') {
            $ManifestImageSet = [string]$manifest.image_set
        }
    } catch {
        Write-Warning "release-manifest.json parse failed: $_ — falling back to 'latest'"
    }
}
$DefaultImageTag = if ($ManifestImageSet) { $ManifestImageSet } else { 'latest' }

# ── Auto-detect boot partition ────────────────────────────────────
function Find-BootPartition {
    # Look for a volume labeled "bootfs"
    $volumes = Get-Volume | Where-Object { $_.FileSystemLabel -eq 'bootfs' }
    foreach ($vol in $volumes) {
        $letter = $vol.DriveLetter
        if ($letter) {
            $path = "${letter}:\"
            if (Test-Path (Join-Path $path 'cmdline.txt')) {
                return $path
            }
        }
    }
    return $null
}

# ── Check client directory ────────────────────────────────────────
function Assert-ClientDir {
    $setupSh = Join-Path $ClientDir 'common' 'scripts' 'setup.sh'
    if (-not (Test-Path $setupSh)) {
        throw "client/ directory is missing or incomplete. Expected: $setupSh"
    }
}

function Update-UserDataRuncmd {
    param(
        [string]$Content,
        [string]$HookPath
    )

    $entry = "  - [bash, $HookPath]"
    $lines = $Content -split "`r?`n"
    $result = New-Object System.Collections.Generic.List[string]
    $patched = $false

    foreach ($line in $lines) {
        if ((-not $patched) -and ($line -match '^(\s*)runcmd:\s*(\[\]|null|~)?\s*$')) {
            $indent = $Matches[1]
            $result.Add("${indent}runcmd:")
            $result.Add("${indent}  - [bash, $HookPath]")
            $patched = $true
        } else {
            $result.Add($line)
        }
    }

    if (-not $patched) {
        if ($result.Count -gt 0 -and $result[$result.Count - 1] -ne '') {
            $result.Add('')
        }
        $result.Add('runcmd:')
        $result.Add($entry)
    }

    return (($result -join "`n").TrimEnd("`r", "`n") + "`n")
}

function Assert-PreparedSdCard {
    param(
        [string]$Dest,
        [string]$Boot,
        [string]$InstallType
    )

    Write-Host ''
    Write-Host '=== Verifying SD card ==='
    $verifyErrors = 0

    Write-Host ''
    Write-Host '--- snapMULTI files ---'
    $requiredBase = @(
        'install.conf',
        'firstboot.sh',
        'release-manifest.json',
        'common/progress.sh',
        'common/logging.sh',
        'common/unified-log.sh',
        'common/sanitize.sh',
        'common/system-tune.sh',
        'common/install-docker.sh',
        'common/install-deps.sh',
        'common/setup-docker.sh',
        'common/wait-network.sh',
        'common/mount-music.sh',
        'common/systemd-snippets.sh',
        'common/release-manifest.sh',
        # v0.8 hardening track additions (mirror bash prepare-sd.sh
        # sources at lines 24, 30, 33 + overlayroot-lifecycle helper
        # sourced by system-tune.sh and ro-mode.sh). The actual file
        # copy already lands these via the top-level `Copy-Item
        # 'common' -Recurse` further down; this verify list catches
        # missing-from-repo regressions before flash.
        'common/cmdline-manager.sh',
        'common/install-profile.sh',
        'common/staging-manifest.sh',
        'common/overlayroot-lifecycle.sh',
        # v0.8 PR9 — sourced unconditionally by firstboot.sh and
        # (guarded) by setup.sh. Missing from SD = immediate firstboot
        # abort under set -euo pipefail.
        'common/path-resolve.sh',
        # v0.8 PR10 — sourced unconditionally by firstboot.sh at
        # line ~115 for the install.conf parse block.
        'common/install-conf-reader.sh',
        # Container manifest SSOT — bind-mounted into metadata service
        # via docker-compose.yml AND sourced by check_containers.sh on
        # every device. Must ship to both server/ and client/ stages.
        'common/container-manifest.txt',
        'common/play-smoke-tone.sh',
        'common/auto-boot-smoke.sh',
        'common/restore-snapmulti-state.sh',
        'common/backup-snapmulti-state.sh',
        'common/snapmulti-state-backup.service',
        'common/snapmulti-state-backup.path',
        'common/snapmulti-state-backup.timer',
        'common/audio/smoke-pass.wav',
        'common/audio/smoke-warn.wav',
        'common/audio/smoke-fail.wav',
        'common/audio/smoke-skip.wav'
    )
    foreach ($file in $requiredBase) {
        $path = Join-Path $Dest $file
        if (Test-Path $path) {
            Write-Host "  [OK] snapmulti/$file"
        } else {
            Write-Host "  [MISSING] snapmulti/$file"
            $verifyErrors++
        }
    }

    if ($InstallType -in @('server', 'both')) {
        foreach ($file in @(
            'server/docker-compose.yml',
            'server/deploy.sh',
            'server/diagnostic.sh',
            'server/scripts/tidal/tidal-meta-bridge.sh',
            'server/config/snapserver.conf',
            'server/config/mpd.conf',
            'server/config/shairport-sync.conf'
        )) {
            $path = Join-Path $Dest $file
            if (Test-Path $path) {
                Write-Host "  [OK] snapmulti/$file"
            } else {
                Write-Host "  [MISSING] snapmulti/$file"
                $verifyErrors++
            }
        }
    }

    if ($InstallType -in @('client', 'both')) {
        foreach ($file in @(
            'client/docker-compose.yml',
            'client/scripts/setup.sh',
            'client/scripts/diagnostic.sh',
            'client/scripts/audio-hat-detect.sh',
            'client/scripts/discover-server.sh',
            'client/scripts/display.sh',
            'client/scripts/display-detect.sh',
            'client/scripts/common/install-deps.sh',
            'client/scripts/common/install-docker.sh',
            'client/scripts/common/systemd-snippets.sh',
            # v0.8: overlayroot-lifecycle.sh is sourced by client's
            # ro-mode.sh + system-tune.sh — must ship to client/.
            'client/scripts/common/overlayroot-lifecycle.sh',
            # v0.8 PR9 — setup.sh sources path-resolve.sh from
            # $COMMON_MODULE_DIR/path-resolve.sh (= /opt/snapclient/
            # scripts/common/ on a real install). Must ship under
            # client/.
            'client/scripts/common/path-resolve.sh',
            # v0.8 PR10 — same shared-modules treatment for the
            # install.conf reader, so a stripped client bundle
            # surfaces the miss at verify time.
            'client/scripts/common/install-conf-reader.sh',
            # Container manifest SSOT — consumed by client-side
            # check_containers.sh too. Must ship with the bundle.
            'client/scripts/common/container-manifest.txt',
            'client/snapclient.conf'
        )) {
            $path = Join-Path $Dest $file
            if (Test-Path $path) {
                Write-Host "  [OK] snapmulti/$file"
            } else {
                Write-Host "  [MISSING] snapmulti/$file"
                $verifyErrors++
            }
        }
    }

    Write-Host ''
    Write-Host '--- OS configuration ---'
    $userData = Join-Path $Boot 'user-data'
    $firstrun = Join-Path $Boot 'firstrun.sh'
    if (Test-Path $userData) {
        if (Select-String -Path $userData -SimpleMatch 'snapmulti/firstboot.sh' -Quiet) {
            Write-Host '  [OK] user-data: runcmd hook present'
        } else {
            Write-Host '  [MISSING] user-data: runcmd hook for firstboot.sh'
            $verifyErrors++
        }
        $metadata = Join-Path $Boot 'meta-data'
        if ((Test-Path $metadata) -and (Select-String -Path $metadata -Pattern '^instance-id:\s*snapmulti-' -Quiet)) {
            $idLine = (Select-String -Path $metadata -Pattern '^instance-id:' | Select-Object -First 1).Line
            Write-Host "  [OK] meta-data: fresh instance-id ($($idLine -replace '^instance-id:\s*', ''))"
        } else {
            Write-Host '  [MISSING] meta-data: instance-id not refreshed -- cloud-init may skip firstboot on reused SDs'
            $verifyErrors++
        }
    } elseif (Test-Path $firstrun) {
        if (Select-String -Path $firstrun -SimpleMatch 'snapmulti/firstboot.sh' -Quiet) {
            Write-Host '  [OK] firstrun.sh: hook present'
        } else {
            Write-Host '  [MISSING] firstrun.sh: hook for firstboot.sh'
            $verifyErrors++
        }
    } else {
        Write-Host '  [WARN] No firstrun.sh or user-data found (manual boot required)'
    }

    Write-Host ''
    if ($verifyErrors -gt 0) {
        throw "Verification failed: $verifyErrors issue(s) found on SD card."
    }
    Write-Host 'All checks passed.'
}

# ── Show install menu ─────────────────────────────────────────────
function Show-Menu {
    Write-Host ''
    Write-Host '  +---------------------------------------------+'
    Write-Host '  |        snapMULTI -- SD Card Setup            |'
    Write-Host '  |                                              |'
    Write-Host '  |  What should this Pi do?                     |'
    Write-Host '  |                                              |'
    Write-Host '  |  1) Audio Player                             |'
    Write-Host '  |     Play music from your server on speakers  |'
    Write-Host '  |                                              |'
    Write-Host '  |  2) Music Server                             |'
    Write-Host '  |     Central hub for Spotify, AirPlay, etc.   |'
    Write-Host '  |                                              |'
    Write-Host '  |  3) Server + Player                          |'
    Write-Host '  |     Both server and local speaker output     |'
    Write-Host '  |                                              |'
    Write-Host '  +---------------------------------------------+'
    Write-Host ''
}

function Get-InstallType {
    while ($true) {
        $choice = Read-Host '  Choose [1-3]'
        switch ($choice) {
            '1' { return 'client' }
            '2' { return 'server' }
            '3' { return 'both' }
            default { Write-Host '  Invalid choice. Enter 1, 2, or 3.' }
        }
    }
}

# ── Music source menu (server/both only) ─────────────────────────
function Show-MusicMenu {
    Write-Host ''
    Write-Host '  +---------------------------------------------+'
    Write-Host '  |        Where is your music?                  |'
    Write-Host '  |                                              |'
    Write-Host '  |  1) Streaming only                           |'
    Write-Host '  |     Spotify, AirPlay, Tidal (no local files) |'
    Write-Host '  |                                              |'
    Write-Host '  |  2) USB drive                                |'
    Write-Host '  |     Plug in before powering on the Pi        |'
    Write-Host '  |                                              |'
    Write-Host '  |  3) Network share (NFS/SMB)                  |'
    Write-Host '  |     Music on a NAS or another computer       |'
    Write-Host '  |                                              |'
    Write-Host '  |  4) I''ll set it up later                     |'
    Write-Host '  |     Mount music dir manually after install   |'
    Write-Host '  |                                              |'
    Write-Host '  +---------------------------------------------+'
    Write-Host ''
    Write-Host '  Most users choose 1 (streaming). Pick 3 if you'
    Write-Host '  have a music collection on a NAS or server.'
    Write-Host ''
}

function Get-MusicSource {
    while ($true) {
        $choice = Read-Host '  Choose [1-4]'
        switch ($choice) {
            '1' { return 'streaming' }
            '2' { return 'usb' }
            '3' { return 'network' }
            '4' { return 'manual' }
            default { Write-Host '  Invalid choice. Enter 1, 2, 3, or 4.' }
        }
    }
}

function Get-NetworkType {
    Write-Host ''
    Write-Host '  Share type:'
    Write-Host '    a) NFS  (Linux/Mac/NAS -- most common)'
    Write-Host '    b) SMB  (Windows share)'
    Write-Host ''
    while ($true) {
        $choice = Read-Host '  Choose [a/b]'
        switch ($choice.ToLower()) {
            'a' { return 'nfs' }
            'b' { return 'smb' }
            default { Write-Host '  Invalid choice. Enter a or b.' }
        }
    }
}

# ── Audio output menus (client/both only) ────────────────────────
# Mirror of the bash audio menu in prepare-sd.sh. See that file for
# the design rationale; this file is the Windows host-side parity.
function Show-AudioMenu {
    Write-Host ''
    Write-Host '  +---------------------------------------------+'
    Write-Host '  |        Audio output                          |'
    Write-Host '  |                                              |'
    Write-Host '  |  1) Auto-detect (recommended)                |'
    Write-Host '  |     Detects HAT via EEPROM/I2C, falls back   |'
    Write-Host '  |     to USB DAC or built-in audio             |'
    Write-Host '  |                                              |'
    Write-Host '  |  2) I have an audio HAT (choose from list)   |'
    Write-Host '  |                                              |'
    Write-Host '  |  3) No HAT -- use Pi built-in audio          |'
    Write-Host '  |     HDMI (TV/monitor) or 3.5mm jack          |'
    Write-Host '  |                                              |'
    Write-Host '  +---------------------------------------------+'
    Write-Host ''
    Write-Host '  Auto-detect is the right choice for >90% of installs.'
    Write-Host '  Use 2 or 3 only if auto-detect failed on a previous attempt.'
    Write-Host ''
}

function Get-AudioType {
    while ($true) {
        $choice = Read-Host '  Choose [1-3]'
        switch ($choice) {
            '1' { return 'auto' }
            '2' { return 'hat' }
            '3' { return 'internal' }
            default { Write-Host '  Invalid choice. Enter 1, 2, or 3.' }
        }
    }
}

# Enumerate supported HATs from $ClientDir\common\audio-hats\*.conf,
# excluding internal-audio (sub-menu 3) and usb-audio (auto-detect).
# Returns @( @{Slug='..'; Name='..'}, ... ) sorted by friendly name.
function Get-SupportedHats {
    param([string]$ClientDir)
    $hatDir = Join-Path $ClientDir 'common\audio-hats'
    if (-not (Test-Path $hatDir)) { return @() }
    $hats = @()
    foreach ($f in Get-ChildItem -Path $hatDir -Filter '*.conf') {
        $slug = [System.IO.Path]::GetFileNameWithoutExtension($f.Name)
        if ($slug -in @('internal-audio', 'usb-audio')) { continue }
        $nameLine = Select-String -Path $f.FullName -Pattern '^HAT_NAME=' -SimpleMatch:$false | Select-Object -First 1
        $name = $slug
        if ($nameLine) {
            # HAT_NAME="..." — strip the variable prefix and surrounding quotes.
            $name = $nameLine.Line -replace '^HAT_NAME=', ''
            $name = $name.Trim('"').Trim("'")
            if (-not $name) { $name = $slug }
        }
        $hats += [PSCustomObject]@{ Slug = $slug; Name = $name }
    }
    return $hats | Sort-Object Name
}

function Show-HatMenu {
    param([array]$Hats)
    Write-Host ''
    Write-Host '  +---------------------------------------------+'
    Write-Host '  |        Choose your audio HAT                 |'
    Write-Host '  +---------------------------------------------+'
    Write-Host ''
    for ($i = 0; $i -lt $Hats.Count; $i++) {
        Write-Host ("  {0,2}) {1}" -f ($i + 1), $Hats[$i].Name)
    }
    Write-Host ''
    Write-Host '  Cancel and return to auto-detect:'
    Write-Host '   0) Back'
    Write-Host ''
}

function Get-HatChoice {
    param([array]$Hats)
    $total = $Hats.Count
    while ($true) {
        $choice = Read-Host "  Choose [0-$total]"
        if ($choice -eq '0') { return 'auto' }
        $n = 0
        if ([int]::TryParse($choice, [ref]$n) -and $n -ge 1 -and $n -le $total) {
            return $Hats[$n - 1].Slug
        }
        Write-Host "  Invalid choice. Enter a number between 0 and $total."
    }
}

function Show-InternalAudioMenu {
    Write-Host ''
    Write-Host '  +---------------------------------------------+'
    Write-Host '  |        Built-in audio output                 |'
    Write-Host '  |                                              |'
    Write-Host '  |  1) HDMI (TV / monitor)                      |'
    Write-Host '  |     Works on Pi 3, Pi 4, Pi 5                |'
    Write-Host '  |                                              |'
    Write-Host '  |  2) 3.5mm jack (Headphones)                  |'
    Write-Host '  |     Works on Pi 3, Pi 4 only                 |'
    Write-Host '  |     (Pi 5 has no analog jack -- pick 1)      |'
    Write-Host '  |                                              |'
    Write-Host '  +---------------------------------------------+'
    Write-Host ''
    Write-Host '  On Bookworm/Trixie the real ALSA card name is'
    Write-Host "  detected at first boot via 'aplay -L' -- you do"
    Write-Host '  not need to know it here.'
    Write-Host ''
}

function Get-InternalOutput {
    while ($true) {
        $choice = Read-Host '  Choose [1-2]'
        switch ($choice) {
            '1' { return 'hdmi' }
            '2' { return 'jack' }
            default { Write-Host '  Invalid choice. Enter 1 or 2.' }
        }
    }
}

function Sanitize-Hostname {
    param([string]$Value)
    $cleaned = $Value -replace '[^A-Za-z0-9.\-]', ''
    return $cleaned.Trim('.').Trim('-')
}

function Sanitize-NfsExport {
    param([string]$Value)
    $cleaned = $Value -replace '[^A-Za-z0-9/._\-]', ''
    if ($cleaned -match '^/') { return $cleaned }
    return ''
}

function Sanitize-ShareName {
    param([string]$Value)
    return ($Value -replace '[^A-Za-z0-9._\-]', '')
}

function Sanitize-SmbUser {
    param([string]$Value)
    return ($Value -replace '[^A-Za-z0-9._@\-]', '')
}

function Get-NfsConfig {
    Write-Host ''
    Write-Host '  NFS Server Configuration'
    Write-Host '  Example: nas.local:/volume1/music'

    $server = ''
    while (-not $server) {
        Write-Host ''
        $rawServer = Read-Host '  Server hostname or IP'
        $server = Sanitize-Hostname $rawServer
        if (-not $server) { Write-Host '  Invalid hostname. Use only letters, numbers, dots, hyphens.' }
    }

    $export = ''
    while (-not $export) {
        $rawExport = Read-Host '  Export path (e.g. /volume1/music)'
        $export = Sanitize-NfsExport $rawExport
        if (-not $export) { Write-Host '  Invalid path. Must start with / (e.g. /volume1/music).' }
    }

    Write-Host ''
    Write-Host "  Will mount: ${server}:${export}"
    return @{ Server = $server; Export = $export }
}

function Get-SmbConfig {
    Write-Host ''
    Write-Host '  SMB/CIFS Configuration'
    Write-Host '  Example: \\mypc\Music  or  mynas/Music'

    $server = ''
    while (-not $server) {
        Write-Host ''
        $rawServer = Read-Host '  Server hostname or IP'
        $server = Sanitize-Hostname $rawServer
        if (-not $server) { Write-Host '  Invalid hostname. Use only letters, numbers, dots, hyphens.' }
    }

    $share = ''
    while (-not $share) {
        $rawShare = Read-Host '  Share name (e.g. Music)'
        # SMB shares with spaces need manual fstab escaping — not supported in auto-setup
        if ($rawShare -match ' ') {
            Write-Host '  Share names with spaces are not supported. Try again without spaces,'
            Write-Host '  or restart and choose option 4 (manual). See docs/USAGE.md.'
            continue
        }
        $share = Sanitize-ShareName $rawShare
        if (-not $share) { Write-Host '  Invalid share name. Use only letters, numbers, dots, underscores, hyphens.' }
    }

    Write-Host ''
    $rawUser = Read-Host '  Username (leave empty for guest)'
    $user = Sanitize-SmbUser $rawUser
    if ($rawUser -and $rawUser -ne $user) {
        Write-Host "  Note: username adjusted to '$user' (unsupported characters removed)"
    }
    $pass = ''
    if ($user) {
        $secPass = Read-Host '  Password' -AsSecureString
        $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secPass)
        try   { $pass = [Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr) }
        finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
    }
    Write-Host ''
    Write-Host "  Will mount: //$server/$share"
    return @{ Server = $server; Share = $share; User = $user; Pass = $pass }
}

# ── Copy helpers ──────────────────────────────────────────────────
function Copy-ServerFiles {
    param([string]$Dest)
    $serverDest = Join-Path $Dest 'server'
    Write-Host '  Copying server files...'
    New-Item -ItemType Directory -Path $serverDest -Force | Out-Null

    Copy-Item (Join-Path $ScriptDir 'deploy.sh') -Destination $serverDest
    $bootTuneSh = Join-Path $ScriptDir 'boot-tune.sh'
    if (Test-Path $bootTuneSh) {
        Copy-Item $bootTuneSh -Destination $serverDest
    }
    $statusSh = Join-Path $ScriptDir 'status.sh'
    if (Test-Path $statusSh) {
        Copy-Item $statusSh -Destination $serverDest
    }
    $smokeSh = Join-Path $ScriptDir 'device-smoke.sh'
    if (Test-Path $smokeSh) {
        Copy-Item $smokeSh -Destination $serverDest
    }
    # Modular smoke checks (scripts/smoke/check_*.sh) — sourced by
    # device-smoke.sh at runtime. Without -Recurse the subdirectory
    # is never copied and the 6 new check modules silently fail to
    # load on the device. Mirrors prepare-sd.sh copy_server_files.
    $smokeDir = Join-Path $ScriptDir 'smoke'
    if (Test-Path $smokeDir) {
        Copy-Item $smokeDir -Destination $serverDest -Recurse
    }
    $reconcileSh = Join-Path $ScriptDir 'docker-driver-reconcile.sh'
    if (Test-Path $reconcileSh) {
        Copy-Item $reconcileSh -Destination $serverDest
    }
    # scripts/tidal/ contains bind-mounted runtime scripts used by
    # docker-compose.yml. Keep it under server/scripts/ so firstboot copies
    # it to /opt/snapmulti/scripts/tidal/.
    $tidalSrc = Join-Path $ScriptDir 'tidal'
    if (Test-Path $tidalSrc) {
        $tidalDest = Join-Path $serverDest 'scripts\tidal'
        New-Item -ItemType Directory -Path $tidalDest -Force | Out-Null
        Copy-Item (Join-Path $tidalSrc '*') -Destination $tidalDest -Recurse -Force
    }
    # diagnostic.sh — install-failed trap in firstboot.sh invokes this to
    # bundle journalctl + install.log + smoke output to the FAT32 boot
    # partition. Without it on the SD, a failed first boot leaves no
    # recoverable diagnostics for a Windows user (no SSH, no console).
    # Mirrors prepare-sd.sh copy_server_files.
    $diagnosticSh = Join-Path $ScriptDir 'diagnostic.sh'
    if (Test-Path $diagnosticSh) {
        Copy-Item $diagnosticSh -Destination $serverDest
    }
    Copy-Item (Join-Path $ProjectDir 'config') -Destination $serverDest -Recurse

    # docker/ contains source files that the compose file bind-mounts
    # into containers (currently metadata-service.py). Without this
    # copy, Docker auto-creates an empty directory at the bind source
    # and the container fails to start with `not a directory: Are you
    # trying to mount a directory onto a file (or vice-versa)?`.
    # See PR #319 (which added the bind-mount), PR #321 (the Linux side
    # of this fix), and the post-merge install failure on pi-server.
    # Copy-Item -Recurse is idempotent on Windows when the destination
    # tree already exists (it merges contents) — no `cp -rT` needed.
    $dockerSrc = Join-Path $ProjectDir 'docker'
    if (Test-Path $dockerSrc) {
        $dockerDest = Join-Path $serverDest 'docker'
        New-Item -ItemType Directory -Path $dockerDest -Force | Out-Null
        Copy-Item (Join-Path $dockerSrc '*') -Destination $dockerDest -Recurse -Force
    }

    Copy-Item (Join-Path $ProjectDir 'docker-compose.yml') -Destination $serverDest

    $envExample = Join-Path $ProjectDir '.env.example'
    if (Test-Path $envExample) {
        Copy-Item $envExample -Destination $serverDest
    }

    # ro-mode helper
    $roMode = Join-Path $ClientDir 'common\scripts\ro-mode.sh'
    if (Test-Path $roMode) {
        Copy-Item $roMode -Destination $serverDest
    }

    # Optional: pre-built MPD database. Only ship it when the target's music
    # source is a network mount — for local USB/disk the db's path pointers
    # likely don't match the new host's library. See #278.
    $mpdDb = Join-Path $ProjectDir 'mpd\data\mpd.db'
    if (Test-Path $mpdDb) {
        if ($MusicSource -eq 'nfs' -or $MusicSource -eq 'smb') {
            $mpdDataDest = Join-Path $serverDest 'mpd\data'
            New-Item -ItemType Directory -Path $mpdDataDest -Force | Out-Null
            Copy-Item $mpdDb -Destination $mpdDataDest
            Write-Host "  Including pre-built MPD database (fast incremental scan, $MusicSource source)"
        } else {
            Write-Host "  Skipping MPD db copy (source=$MusicSource, fresh scan on first boot)"
        }
    }
}

function Copy-ClientFiles {
    param([string]$Dest)
    $clientDest = Join-Path $Dest 'client'
    Write-Host '  Copying client files...'
    New-Item -ItemType Directory -Path $clientDest -Force | Out-Null

    # Core install files
    Copy-Item (Join-Path $ClientDir 'install\snapclient.conf') -Destination $clientDest

    # Project files from common/
    foreach ($item in @('docker-compose.yml', '.env.example', 'audio-hats', 'docker', 'public')) {
        $itemPath = Join-Path $ClientDir "common\$item"
        if (Test-Path $itemPath) {
            if ((Get-Item $itemPath).PSIsContainer) {
                Copy-Item $itemPath -Destination $clientDest -Recurse
            } else {
                Copy-Item $itemPath -Destination $clientDest
            }
        }
    }

    # Setup scripts
    $scriptsDest = Join-Path $clientDest 'scripts'
    New-Item -ItemType Directory -Path $scriptsDest -Force | Out-Null
    Copy-Item (Join-Path $ClientDir 'common\scripts\setup.sh') -Destination $scriptsDest
    # Pi Zero 2W native snapclient install path (firstboot.sh selects
    # this script when /proc/device-tree/model matches "Zero 2 W").
    $setupZero2w = Join-Path $ClientDir 'common\scripts\setup-zero2w.sh'
    if (Test-Path $setupZero2w) {
        Copy-Item $setupZero2w -Destination $scriptsDest
    }

    # Audio HAT detection module (required by setup.sh)
    $hatDetect = Join-Path $ClientDir 'common\scripts\audio-hat-detect.sh'
    if (Test-Path $hatDetect) {
        Copy-Item $hatDetect -Destination $scriptsDest
    }

    # Shared modules from server scripts/common/
    $commonDest = Join-Path $scriptsDest 'common'
    New-Item -ItemType Directory -Path $commonDest -Force | Out-Null
    foreach ($shared in @('install-deps.sh', 'install-docker.sh', 'system-tune.sh', 'overlayroot-lifecycle.sh', 'unified-log.sh', 'logging.sh', 'sanitize.sh', 'systemd-snippets.sh', 'path-resolve.sh', 'install-conf-reader.sh', 'container-manifest.txt')) {
        $sharedPath = Join-Path $ScriptDir "common\$shared"
        if (Test-Path $sharedPath) {
            Copy-Item $sharedPath -Destination $commonDest
        }
    }

    # initramfs-hooks/ — required by overlayroot-lifecycle.sh's
    # install_initramfs_lzma_hook (snapmulti-lzma copy_exec's liblzma.so.5
    # so kmod inside initramfs can decompress overlay.ko.xz). Mirror of
    # scripts/prepare-sd.sh copy_client_files lines 596-610.
    # Idempotent pattern: pre-create dest + copy contents via `\*` glob.
    # `Copy-Item $src -Destination $dest -Recurse` would nest the source
    # dir inside dest on re-run, leaving the runtime glob in
    # overlayroot-lifecycle.sh with nothing to find.
    $initramfsHooksSrc = Join-Path $ScriptDir 'common\initramfs-hooks'
    if (Test-Path $initramfsHooksSrc) {
        $initramfsHooksDest = Join-Path $commonDest 'initramfs-hooks'
        New-Item -ItemType Directory -Path $initramfsHooksDest -Force | Out-Null
        Copy-Item (Join-Path $initramfsHooksSrc '*') -Destination $initramfsHooksDest -Recurse -Force
    }

    # boot-tune.sh and device-smoke.sh are server scripts but client also needs them
    $bootTune = Join-Path $ScriptDir 'boot-tune.sh'
    if (Test-Path $bootTune) {
        Copy-Item $bootTune -Destination $scriptsDest
    }
    # client also needs it to prevent Docker silently regressing to overlay2
    $reconcileSh = Join-Path $ScriptDir 'docker-driver-reconcile.sh'
    if (Test-Path $reconcileSh) {
        Copy-Item $reconcileSh -Destination $scriptsDest
    }
    $smokeSh = Join-Path $ScriptDir 'device-smoke.sh'
    if (Test-Path $smokeSh) {
        Copy-Item $smokeSh -Destination $scriptsDest
    }
    # diagnostic.sh — see Copy-ServerFiles for context.
    $diagnosticSh = Join-Path $ScriptDir 'diagnostic.sh'
    if (Test-Path $diagnosticSh) {
        Copy-Item $diagnosticSh -Destination $scriptsDest
    }
    # Modular smoke checks dir — mirrors prepare-sd.sh copy_client_files.
    # Client firstboot path is recursive so once smoke/ lands here it
    # propagates to /opt/snapclient/scripts/smoke/ automatically.
    $smokeDir = Join-Path $ScriptDir 'smoke'
    if (Test-Path $smokeDir) {
        Copy-Item $smokeDir -Destination $scriptsDest -Recurse
    }

    $roMode = Join-Path $ClientDir 'common\scripts\ro-mode.sh'
    if (Test-Path $roMode) {
        Copy-Item $roMode -Destination $scriptsDest
    }

    $discoverSh = Join-Path $ClientDir 'common\scripts\discover-server.sh'
    if (Test-Path $discoverSh) {
        Copy-Item $discoverSh -Destination $scriptsDest
    }

    $displaySh = Join-Path $ClientDir 'common\scripts\display.sh'
    if (Test-Path $displaySh) {
        Copy-Item $displaySh -Destination $scriptsDest
    }

    $displayDetect = Join-Path $ClientDir 'common\scripts\display-detect.sh'
    if (Test-Path $displayDetect) {
        Copy-Item $displayDetect -Destination $scriptsDest
    }

    # Systemd service files (display detection boot service)
    $systemdSrc = Join-Path $ClientDir 'common\systemd'
    if (Test-Path $systemdSrc) {
        $systemdDest = Join-Path $clientDest 'systemd'
        Copy-Item $systemdSrc -Destination $systemdDest -Recurse -Force
    }
}

# ── Main ──────────────────────────────────────────────────────────

# Detect boot partition
if (-not $Boot) {
    $Boot = Find-BootPartition
    if ($Boot) {
        Write-Host "Auto-detected boot partition: $Boot"
    } else {
        Write-Error @"
Could not find boot partition.

Usage: .\scripts\prepare-sd.ps1 -Boot E:\
       (replace E: with your SD card's boot drive letter)
"@
        exit 1
    }
}

# Validate
if (-not (Test-Path $Boot -PathType Container)) {
    Write-Error "$Boot is not a directory."
    exit 1
}

$configTxt = Join-Path $Boot 'config.txt'
$cmdlineTxt = Join-Path $Boot 'cmdline.txt'
if (-not (Test-Path $configTxt) -and -not (Test-Path $cmdlineTxt)) {
    Write-Error "$Boot does not look like a Raspberry Pi boot partition (missing config.txt and cmdline.txt)."
    exit 1
}

# Choose install type
Show-Menu
$InstallType = Get-InstallType

# Check client directory if needed
if ($InstallType -in @('client', 'both')) {
    Assert-ClientDir
}

Write-Host ''
Write-Host "Installing as: $InstallType"
Write-Host ''

# ── Audio output (client/both only) ──────────────────────────────
$AudioHat = 'auto'
$AudioInternalOutput = ''
if ($InstallType -in @('client', 'both')) {
    Show-AudioMenu
    $audioType = Get-AudioType
    switch ($audioType) {
        'auto' { $AudioHat = 'auto' }
        'hat' {
            $hats = Get-SupportedHats -ClientDir $ClientDir
            Show-HatMenu -Hats $hats
            $AudioHat = Get-HatChoice -Hats $hats
        }
        'internal' {
            $AudioHat = 'internal-audio'
            Show-InternalAudioMenu
            $AudioInternalOutput = Get-InternalOutput
        }
    }
    Write-Host ''
    if ($AudioInternalOutput) {
        Write-Host "Audio: $AudioHat ($AudioInternalOutput)"
    } else {
        Write-Host "Audio: $AudioHat"
    }
    Write-Host ''
}

# ── Music source (server/both only) ─────────────────────────────
$MusicSource = ''
$NfsServer = ''
$NfsExport = ''
$SmbServer = ''
$SmbShare = ''
$SmbUser = ''
$SmbPass = ''

if ($InstallType -in @('server', 'both')) {
    Show-MusicMenu
    $MusicSource = Get-MusicSource

    if ($MusicSource -eq 'network') {
        $netType = Get-NetworkType
        $MusicSource = $netType
        if ($netType -eq 'nfs') {
            $nfsCfg = Get-NfsConfig
            $NfsServer = $nfsCfg.Server
            $NfsExport = $nfsCfg.Export
        } else {
            $smbCfg = Get-SmbConfig
            $SmbServer = $smbCfg.Server
            $SmbShare = $smbCfg.Share
            $SmbUser = $smbCfg.User
            $SmbPass = $smbCfg.Pass
        }
    }
}

# ── Copy files to SD card ─────────────────────────────────────────
$Dest = Join-Path $Boot 'snapmulti'
Write-Host "Copying files to $Dest ..."

# Clean previous install
if ((Test-Path $Dest) -and $Dest.EndsWith('snapmulti')) {
    Remove-Item $Dest -Recurse -Force
}
New-Item -ItemType Directory -Path $Dest -Force | Out-Null

# install.conf
$timestamp = Get-Date -Format 'o'
$confContent = @"
# snapMULTI Installation Configuration
# Generated by prepare-sd.ps1 on $timestamp
INSTALL_TYPE=$InstallType
MUSIC_SOURCE=$MusicSource
NFS_SERVER=$NfsServer
NFS_EXPORT=$NfsExport
SMB_SERVER=$SmbServer
SMB_SHARE=$SmbShare
# Audio output (client/both only — server installs ignore these)
AUDIO_HAT=$AudioHat
AUDIO_INTERNAL_OUTPUT=$AudioInternalOutput
# Release identity comes from release-manifest.json on the SD (single SSOT,
# staged below). Do not duplicate SNAPMULTI_RELEASE / SNAPMULTI_IMAGE_SET here.
# Advanced options
# (PowerShell prep currently uses defaults — the bash side has an
# interactive Advanced menu that lets the user toggle these. Parity
# work tracked in #322 follow-up.)
ENABLE_READONLY=true
SKIP_UPGRADE=false
IMAGE_TAG=$DefaultImageTag
VERBOSE_INSTALL=false
TEST_TONE=true
SMB_USER=$SmbUser
SMB_PASS=$SmbPass
"@
[System.IO.File]::WriteAllText((Join-Path $Dest 'install.conf'), $confContent, $Utf8NoBom)

# Always: firstboot + common
Copy-Item (Join-Path $ScriptDir 'firstboot.sh') -Destination $Dest
Copy-Item (Join-Path $ScriptDir 'common') -Destination $Dest -Recurse

# Stage release-manifest.json next to install.conf so firstboot can read
# it via "$SNAP_BOOT/release-manifest.json". Guarded copy so the script
# tolerates a custom-built tree without the manifest (parser already
# returns empty in that case).
if (Test-Path $ManifestPath) {
    Copy-Item $ManifestPath -Destination $Dest
}

# Mode-specific files
switch ($InstallType) {
    'server' { Copy-ServerFiles -Dest $Dest }
    'client' { Copy-ClientFiles -Dest $Dest }
    'both'   { Copy-ServerFiles -Dest $Dest; Copy-ClientFiles -Dest $Dest }
}

# Strip Python bytecode caches dragged along from the host tree
# (mirrors prepare-sd.sh post-copy cleanup).
Get-ChildItem -Path $Dest -Recurse -Force -Directory -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -eq '__pycache__' } |
    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
Get-ChildItem -Path $Dest -Recurse -Force -File -Filter '*.pyc' -ErrorAction SilentlyContinue |
    Remove-Item -Force -ErrorAction SilentlyContinue

# ── Write version files ──────────────────────────────────────────
# Both use the same version tag from the monorepo (with "v" prefix).
# NB: NO `--abbrev=0` — keep the `-<N>-g<sha>` suffix from `git describe` so a
# flash from a main HEAD past the latest tag bakes the disambiguated version
# instead of the bare tag. See the matching comment in prepare-sd.sh:829.
try {
    $gitVersion = & git -C $ProjectDir describe --tags 2>$null
    if (-not $gitVersion) { $gitVersion = 'dev' }
} catch {
    $gitVersion = 'dev'
}
if ($InstallType -in @('server', 'both')) {
    [System.IO.File]::WriteAllText((Join-Path $Dest 'server/.version'), $gitVersion, $Utf8NoBom)
}
if ($InstallType -in @('client', 'both')) {
    [System.IO.File]::WriteAllText((Join-Path $Dest 'client/VERSION'), $gitVersion, $Utf8NoBom)
}

$size = (Get-ChildItem $Dest -Recurse | Measure-Object -Property Length -Sum).Sum / 1MB
Write-Host ("  Copied {0:N1} MB to boot partition." -f $size)

# ── Set temporary 800x600 resolution ──────────────────────────────
$cmdline = Join-Path $Boot 'cmdline.txt'
$setupVideo = 'video=HDMI-A-1:800x600@60'
if (Test-Path $cmdline) {
    $content = [System.IO.File]::ReadAllText($cmdline).TrimEnd()
    if ($content -notmatch 'video=HDMI-A-1:') {
        $content = "$content $setupVideo"
        Write-Host '  Set temporary setup resolution (800x600) in cmdline.txt'
    }
    # Mask units we know we never want active. Parsed by PID 1 before
    # any unit starts; survives overlayroot upper-layer wipes (a
    # post-firstboot systemctl mask would be lost on every reboot).
    # Sync with scripts/prepare-sd.sh BOOT_MASK_UNITS array.
    $bootMaskUnits = @(
        'NetworkManager-wait-online.service'
    )
    foreach ($unit in $bootMaskUnits) {
        $token = "systemd.mask=$unit"
        if ($content -notmatch ('\b' + [regex]::Escape($token) + '\b')) {
            $content = "$content $token"
            Write-Host "  Added systemd.mask=$unit to cmdline.txt"
        }
    }

    # IPv6 kernel state (ADR-008 supersedes ADR-007). Default ON —
    # software defenses (Avahi use-ipv6=no, snapclient IPv4 SRV pin,
    # fb-display IPv4 filter) carry the load. Tidal Connect needs the
    # IPv6 stack for its WebSocket listen. Opt back in to disable via
    # DISABLE_IPV6=true.
    $disableIpv6 = $env:DISABLE_IPV6
    if (-not $disableIpv6) { $disableIpv6 = 'false' }
    if ($disableIpv6 -eq 'true') {
        $ipv6Flag = 'ipv6.disable=1'
        if ($content -notmatch ('\b' + [regex]::Escape($ipv6Flag) + '\b')) {
            $content = "$content $ipv6Flag"
            Write-Host '  IPv6 disabled at kernel cmdline (DISABLE_IPV6=true)'
        }
    } else {
        Write-Host '  IPv6 left enabled at kernel (default — Tidal Connect needs it)'
    }

    [System.IO.File]::WriteAllText($cmdline, "$content`n", $Utf8NoBom)
}

# ── Patch user-data (Bookworm+ cloud-init) ────────────────────────
$userData = Join-Path $Boot 'user-data'
$firstrun = Join-Path $Boot 'firstrun.sh'
# Bullseye mounts boot at /boot, Bookworm+ at /boot/firmware
$hookBullseye = 'bash /boot/snapmulti/firstboot.sh'
$hookBookworm = 'bash /boot/firmware/snapmulti/firstboot.sh'

if (Test-Path $firstrun) {
    # Legacy Pi Imager (Bullseye): boot partition is /boot
    $hook = $hookBullseye
    $frContent = [System.IO.File]::ReadAllText($firstrun)
    # Normalize CRLF to LF so (?m)^ anchors work reliably
    $frContent = $frContent.Replace("`r`n", "`n")
    if ($frContent -match 'snapmulti/firstboot\.sh') {
        Write-Host 'firstrun.sh already patched, skipping.'
    } else {
        Write-Host 'Patching firstrun.sh to chain installer ...'
        $insertLine = "# snapMULTI auto-install`n$hook`n"
        if ($frContent -match '(?m)^rm -f.*firstrun\.sh') {
            $frContent = $frContent -replace '(?m)(^rm -f.*firstrun\.sh)', "$insertLine`$1"
        } else {
            $frContent = $frContent -replace '(?m)(^exit 0)', "$insertLine`$1"
        }
        [System.IO.File]::WriteAllText($firstrun, $frContent, $Utf8NoBom)
        Write-Host '  firstrun.sh patched.'
    }
} elseif (Test-Path $userData) {
    # Modern Pi Imager (Bookworm+): boot partition is /boot/firmware
    $hook = $hookBookworm
    $udContent = [System.IO.File]::ReadAllText($userData)
    if ($udContent -match 'snapmulti/firstboot\.sh') {
        Write-Host 'user-data already patched, skipping.'
    } else {
        Write-Host 'Patching user-data to run installer on first boot ...'
        $hookPath = $hook -replace '^bash ', ''
        $udContent = Update-UserDataRuncmd -Content $udContent -HookPath $hookPath
        [System.IO.File]::WriteAllText($userData, $udContent, $Utf8NoBom)
        Write-Host '  user-data patched.'
    }
} else {
    Write-Host ''
    Write-Host 'NOTE: No firstrun.sh or user-data found on boot partition.'
    Write-Host '  After booting, SSH into the Pi and run:'
    Write-Host '    sudo bash /boot/firmware/snapmulti/firstboot.sh'
    Write-Host ''
}

# ── Refresh cloud-init meta-data (NoCloud instance-id) ────────────
# Cloud-init treats two boots with the same instance-id as the SAME instance and skips runcmd / firstboot.
# Always write a fresh ID so this boot is "new" even if the SD was previously booted.
$metadata = Join-Path $Boot 'meta-data'
if (Test-Path $userData) {
    $newInstanceId = "snapmulti-$([guid]::NewGuid().ToString().ToLower())"
    if (Test-Path $metadata) {
        $oldLine = Select-String -Path $metadata -Pattern '^instance-id:' -SimpleMatch:$false -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($oldLine) {
            $oldId = ($oldLine.Line -replace '^instance-id:\s*', '').Trim()
            if ($oldId) {
                Write-Host "WARNING: meta-data already had instance-id=$oldId."
                Write-Host '         If this SD was previously booted, cloud-init would have skipped firstboot.'
                Write-Host "         Refreshing to instance-id=$newInstanceId."
            }
        }
    }
    $metaContent = "instance-id: $newInstanceId`n# Regenerated by prepare-sd.ps1 on every run so cloud-init sees a new instance.`n"
    [System.IO.File]::WriteAllText($metadata, $metaContent, $Utf8NoBom)
    Write-Host "  meta-data written (instance-id=$newInstanceId)"
}

# ── Verify SD card contents ───────────────────────────────────────
Assert-PreparedSdCard -Dest $Dest -Boot $Boot -InstallType $InstallType

# ── Eject SD card ─────────────────────────────────────────────────
Write-Host ''
Write-Host 'Ejecting SD card...'
try {
    $driveLetter = $Boot.Substring(0, 2)  # e.g., "E:"
    $shell = New-Object -ComObject Shell.Application
    $shell.Namespace(17).ParseName($driveLetter).InvokeVerb('Eject')
    Write-Host '  SD card ejected.'
} catch {
    Write-Host '  WARNING: Could not eject -- please eject manually via File Explorer.'
}

# ── Done ──────────────────────────────────────────────────────────
Write-Host ''
Write-Host '=== SD card ready! ==='
Write-Host ''
Write-Host 'Next steps:'
Write-Host '  1. Remove the SD card'
Write-Host '  2. Insert into Raspberry Pi'
Write-Host '  3. Power on -- installation takes ~10-15 minutes, then auto-reboots'
switch ($InstallType) {
    { $_ -in 'server', 'both' } {
        Write-Host '  4. Open this URL in a browser (replace <hostname> with the one you set in Imager):'
        Write-Host '       http://<hostname>.local:8083/         <-- start here: lists every server endpoint'
        Write-Host ''
        Write-Host '     Direct links if you prefer:'
        Write-Host '       http://<hostname>.local:1780          Snapweb (volume, rooms, source)'
        Write-Host '       http://<hostname>.local:8180          myMPD (browse and play library)'
        Write-Host '       http://<hostname>.local:8083/status   Status page (containers, audio, mDNS)'
        Write-Host '  5. Cast from your apps:'
        Write-Host "       Spotify  -> select '<hostname> Spotify' in the Spotify app (Premium required)"
        Write-Host "       AirPlay  -> AirPlay icon -> '<hostname> AirPlay'"
        Write-Host "       Tidal    -> cast to '<hostname> Tidal' (ARM/Pi only, enabled by default)"
    }
    'client' {
        Write-Host '  4. The player auto-discovers your snapMULTI server via mDNS'
        Write-Host '  5. Check it joined on the server''s landing page:'
        Write-Host '       http://<server-hostname>.local:8083/  (lists Snapweb, myMPD, status, ...)'
    }
}
Write-Host ''
