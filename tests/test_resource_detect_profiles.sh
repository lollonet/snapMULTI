#!/usr/bin/env bash
# Model × RAM → resource profile mapping in scripts/common/resource-detect.sh
# (detect_profile_from_hardware), shared by deploy.sh (server, generic
# performance threshold 8000) and client setup.sh (default 4000).
#
# RAM values are realistic /proc/meminfo MemTotal figures, which sit well
# below the nominal size. Regressions covered:
#   - Pi 4 4GB (MemTotal ~3.8 GB) fell under a 4000 MB cut-off → standard
#   - Pi 4 1GB got standard limits
#   - every Pi 5 got performance regardless of RAM (1 GB / 2 GB exist)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log_info() { :; }
log_warn() { :; }
# shellcheck source=../scripts/common/resource-detect.sh
source "$SCRIPT_DIR/../scripts/common/resource-detect.sh"

pass=0
fail=0

# check <model> <MemTotal MB> <expected server> <expected client>
check() {
    local model="$1" ram="$2" want_server="$3" want_client="$4"
    local got_server got_client
    DETECTED_PI_MODEL="$model"
    DETECTED_RAM_MB="$ram"
    got_server=$(detect_profile_from_hardware 8000)
    got_client=$(detect_profile_from_hardware)
    local desc="${model:-generic} ${ram}MB"
    if [[ "$got_server" == "$want_server" && "$got_client" == "$want_client" ]]; then
        echo "  PASS: $desc -> server=$got_server client=$got_client"
        pass=$((pass + 1))
    else
        echo "  FAIL: $desc -> server=$got_server (want $want_server) client=$got_client (want $want_client)"
        fail=$((fail + 1))
    fi
}

echo "## Raspberry Pi models"
check "Raspberry Pi Zero 2 W Rev 1.0"        427   minimal     minimal
check "Raspberry Pi 3 Model B Rev 1.2"       909   minimal     minimal
check "Raspberry Pi 3 Model B Plus Rev 1.3"  906   minimal     minimal
check "Raspberry Pi 4 Model B Rev 1.1"       908   minimal     minimal
check "Raspberry Pi 4 Model B Rev 1.2"       1848  standard    standard
check "Raspberry Pi 4 Model B Rev 1.4"       1906  standard    standard
check "Raspberry Pi 4 Model B Rev 1.4"       3793  performance performance
check "Raspberry Pi 4 Model B Rev 1.5"       3884  performance performance
check "Raspberry Pi 4 Model B Rev 1.4"       7809  performance performance
check "Raspberry Pi 400 Rev 1.0"             3796  performance performance
check "Raspberry Pi 5 Model B Rev 1.1"       945   minimal     minimal
check "Raspberry Pi 5 Model B Rev 1.0"       2010  standard    standard
check "Raspberry Pi 5 Model B Rev 1.0"       4045  performance performance
check "Raspberry Pi 5 Model B Rev 1.0"       8059  performance performance
check "Raspberry Pi 5 Model B Rev 1.1"       16219 performance performance

echo
echo "## Generic (x86_64 / unknown model)"
check ""  1024   minimal     minimal
check ""  1999   minimal     minimal
check ""  3900   standard    standard
check ""  6000   standard    performance
check ""  7900   standard    performance
check ""  16000  performance performance

echo
echo "## Every result is a profile deploy.sh / setup.sh accept"
bad=0
for model in "" "Raspberry Pi 3 Model B" "Raspberry Pi 4 Model B" "Raspberry Pi 5 Model B" "Raspberry Pi Zero 2 W"; do
    for ram in 0 256 512 1000 1500 2000 3000 4000 8000 16000; do
        # shellcheck disable=SC2034  # read by detect_profile_from_hardware
        DETECTED_PI_MODEL="$model"
        # shellcheck disable=SC2034  # read by detect_profile_from_hardware
        DETECTED_RAM_MB="$ram"
        for threshold in "" 8000; do
            p=$(detect_profile_from_hardware ${threshold:+"$threshold"})
            case "$p" in
                minimal|standard|performance) ;;
                *) echo "  FAIL: '${model:-generic}' ${ram}MB threshold=${threshold:-default} -> '$p'"; bad=$((bad + 1)) ;;
            esac
        done
    done
done
if (( bad == 0 )); then
    echo "  PASS: all model/RAM/threshold combinations yield minimal|standard|performance"
    pass=$((pass + 1))
else
    fail=$((fail + bad))
fi

echo
echo "## Summary"
echo "  Passed: $pass"
echo "  Failed: $fail"
[[ $fail -eq 0 ]]
