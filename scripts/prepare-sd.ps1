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

# ── Check client submodule ────────────────────────────────────────
function Assert-ClientSubmodule {
    $setupPath = Join-Path $ClientDir 'common\scripts\setup.sh'
    if (-not (Test-Path $setupPath)) {
        Write-Host 'Client submodule not initialized. Fetching...'
        & git -C $ProjectDir submodule update --init --recursive
        if (-not (Test-Path $setupPath)) {
            Write-Error 'client/ submodule is missing. Run: git submodule update --init --recursive'
            exit 1
        }
    }
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

# ── Copy helpers ──────────────────────────────────────────────────
function Copy-ServerFiles {
    param([string]$Dest)
    $serverDest = Join-Path $Dest 'server'
    Write-Host '  Copying server files...'
    New-Item -ItemType Directory -Path $serverDest -Force | Out-Null

    Copy-Item (Join-Path $ScriptDir 'deploy.sh') -Destination $serverDest
    Copy-Item (Join-Path $ProjectDir 'config') -Destination $serverDest -Recurse
    Copy-Item (Join-Path $ProjectDir 'docker-compose.yml') -Destination $serverDest

    $envExample = Join-Path $ProjectDir '.env.example'
    if (Test-Path $envExample) {
        Copy-Item $envExample -Destination $serverDest
    }

    # Dockerfiles
    foreach ($df in @('Dockerfile.snapserver', 'Dockerfile.shairport-sync', 'Dockerfile.mpd', 'Dockerfile.tidal')) {
        $dfPath = Join-Path $ProjectDir $df
        if (Test-Path $dfPath) {
            Copy-Item $dfPath -Destination $serverDest
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

    # Setup script
    $scriptsDest = Join-Path $clientDest 'scripts'
    New-Item -ItemType Directory -Path $scriptsDest -Force | Out-Null
    Copy-Item (Join-Path $ClientDir 'common\scripts\setup.sh') -Destination $scriptsDest

    $roMode = Join-Path $ClientDir 'common\scripts\ro-mode.sh'
    if (Test-Path $roMode) {
        Copy-Item $roMode -Destination $scriptsDest
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

# Check client submodule if needed
if ($InstallType -in @('client', 'both')) {
    Assert-ClientSubmodule
}

Write-Host ''
Write-Host "Installing as: $InstallType"
Write-Host ''

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
"@
[System.IO.File]::WriteAllText((Join-Path $Dest 'install.conf'), $confContent, $Utf8NoBom)

# Always: firstboot + common
Copy-Item (Join-Path $ScriptDir 'firstboot.sh') -Destination $Dest
Copy-Item (Join-Path $ScriptDir 'common') -Destination $Dest -Recurse

# Mode-specific files
switch ($InstallType) {
    'server' { Copy-ServerFiles -Dest $Dest }
    'client' { Copy-ClientFiles -Dest $Dest }
    'both'   { Copy-ServerFiles -Dest $Dest; Copy-ClientFiles -Dest $Dest }
}

$size = (Get-ChildItem $Dest -Recurse | Measure-Object -Property Length -Sum).Sum / 1MB
Write-Host ("  Copied {0:N1} MB to boot partition." -f $size)

# ── Set temporary 800x600 resolution ──────────────────────────────
$cmdline = Join-Path $Boot 'cmdline.txt'
$setupVideo = 'video=HDMI-A-1:800x600@60'
if (Test-Path $cmdline) {
    $content = [System.IO.File]::ReadAllText($cmdline).TrimEnd()
    if ($content -notmatch 'video=HDMI-A-1:') {
        [System.IO.File]::WriteAllText($cmdline, "$content $setupVideo`n", $Utf8NoBom)
        Write-Host '  Set temporary setup resolution (800x600) in cmdline.txt'
    }
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
        if ($udContent -match '(?m)^runcmd:') {
            $udContent = $udContent -replace '(?m)(^runcmd:)', "`$1`n  - [bash, /boot/firmware/snapmulti/firstboot.sh]"
        } else {
            $udContent += "`n`nruncmd:`n  - [bash, /boot/firmware/snapmulti/firstboot.sh]`n"
        }
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
Write-Host '  3. Power on -- installation takes ~5-10 minutes, then auto-reboots'
switch ($InstallType) {
    { $_ -in 'server', 'both' } { Write-Host '  4. Access http://<your-hostname>.local:8180' }
    'client' { Write-Host '  4. The player will auto-discover your snapMULTI server' }
}
Write-Host ''
