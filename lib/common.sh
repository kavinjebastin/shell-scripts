#!/usr/bin/env bash
# shellcheck disable=SC2034
set -euo pipefail

readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m'

info()    { printf "${BLUE}[INFO]${NC} %s\n" "$*"; }
warn()    { printf "${YELLOW}[WARN]${NC} %s\n" "$*" >&2; }
error()   { printf "${RED}[ERROR]${NC} %s\n" "$*" >&2; }
success() { printf "${GREEN}[OK]${NC} %s\n" "$*"; }

cleanup() {
    local exit_code=$?
    if [[ $exit_code -ne 0 ]]; then
        error "Script failed with exit code $exit_code"
    fi
}
trap cleanup EXIT

require_root() {
    if [[ $EUID -ne 0 ]]; then
        error "This script must be run as root (use sudo)"
        exit 1
    fi
}

require_user() {
    if [[ $EUID -eq 0 ]]; then
        error "This script should not be run as root"
        exit 1
    fi
}

require_ubuntu() {
    if [[ ! -f /etc/os-release ]]; then
        error "Cannot detect OS — /etc/os-release not found"
        exit 1
    fi
    local id
    id=$(. /etc/os-release && echo "$ID")
    if [[ "$id" != "ubuntu" ]]; then
        error "This script only supports Ubuntu (detected: $id)"
        exit 1
    fi
}

require_cmd() {
    local cmd="$1"
    if command -v "$cmd" &>/dev/null; then
        return 0
    fi
    info "Installing missing dependency: $cmd"
    if [[ $EUID -eq 0 ]]; then
        apt-get update -qq && apt-get install -y -qq "$cmd"
    else
        sudo apt-get update -qq && sudo apt-get install -y -qq "$cmd"
    fi
    if ! command -v "$cmd" &>/dev/null; then
        error "Failed to install $cmd"
        exit 1
    fi
    success "Installed $cmd"
}

is_installed() {
    command -v "$1" &>/dev/null
}

require_cmd_installer() {
    local cmd="$1" installer_url="$2"
    if command -v "$cmd" &>/dev/null; then
        return 0
    fi
    if [[ -z "$installer_url" ]]; then
        error "No installer URL provided for $cmd"
        exit 1
    fi
    info "Installing missing dependency via vendor installer: $cmd"
    info "Source: $installer_url"
    if ! curl -fsSL "$installer_url" | sudo bash; then
        error "Installer failed for $cmd"
        exit 1
    fi
    if ! command -v "$cmd" &>/dev/null; then
        error "Installer completed but '$cmd' still not found in PATH"
        exit 1
    fi
    success "Installed $cmd"
}

file_contains() {
    local file="$1" pattern="$2"
    grep -qF "$pattern" "$file" 2>/dev/null
}

line_in_file() {
    local line="$1" file="$2"
    if ! file_contains "$file" "$line"; then
        echo "$line" >> "$file"
        info "Added to $file: $line"
    fi
}
