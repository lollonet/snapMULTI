#!/usr/bin/env bash
# Common logging utilities for snapMULTI scripts
# Provides consistent colored output across all scripts

# Colors (only if terminal supports them)
if [[ -t 2 ]]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    CYAN='\033[0;36m'
    BOLD='\033[1m'
    NC='\033[0m'  # No Color
else
    RED=''
    GREEN=''
    YELLOW=''
    BLUE=''
    CYAN=''
    BOLD=''
    NC=''
fi

# Logging functions - all output to stderr to not interfere with stdout
info()  { echo -e "${BLUE}[INFO]${NC} $*" >&2; }
ok()    { echo -e "${GREEN}[OK]${NC} $*" >&2; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*" >&2; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
step()  { echo -e "\n${CYAN}${BOLD}==> $*${NC}" >&2; }
debug() { [[ "${DEBUG:-0}" == "1" ]] && echo -e "[DEBUG] $*" >&2; }
