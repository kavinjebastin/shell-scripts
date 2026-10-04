#!/usr/bin/env bash
set -euo pipefail

COMMON_URL="https://raw.githubusercontent.com/kavinjebastin/shell-scripts/main/lib/common.sh"
LIB_PATH="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../.." && pwd)/lib/common.sh"
if [[ -f "$LIB_PATH" ]]; then
    # shellcheck source=../../lib/common.sh
    source "$LIB_PATH"
else
    eval "$(curl -fsSL "$COMMON_URL")"
fi

require_ubuntu
require_root
require_cmd curl
require_cmd unzip

ELAN_SENSOR_ID="04f3:0c4b"
FPC_SENSOR_ID="10a5:9800"
DRIVER_URL="https://download.lenovo.com/pccbbs/mobiles/r1slf01w.zip"
DRIVER_SHA256="87d7df1a4364d96f635dc85359d21f45afd9b6c56b3476be31d8e4c8f7e0960f"
DRIVER_SO="libfprint-2-tod1-elan.so"
LIB_DIR="/usr/lib/x86_64-linux-gnu"
TOD_DIR="$LIB_DIR/libfprint-2/tod-1"
TARGET_USER="${SUDO_USER:-$(logname)}"
WORK_DIR="$(mktemp -d)"
DRIVER_ZIP="$WORK_DIR/r1slf01w.zip"

if ! lsusb | grep -q "$ELAN_SENSOR_ID"; then
    error "ELAN fingerprint sensor ($ELAN_SENSOR_ID) not found"
    error "This script is for Lenovo ThinkPad E14 Gen 3 with ELAN sensor"
    if lsusb | grep -q "$FPC_SENSOR_ID"; then
        error "FPC sensor ($FPC_SENSOR_ID) detected — use setup-fingerprint-thinkpad-e14-gen4.sh instead"
    fi
    exit 1
fi
success "ELAN fingerprint sensor detected"

info "Removing leftovers from the Gen 4 FPC driver, if any..."
rm -f "$LIB_DIR/libfpcbep.so" "$LIB_DIR/libfprint-2.so" /lib/udev/rules.d/60-libfprint-2-device-fpc.rules
rm -rf /var/log/fpc
apt-mark unhold libfprint-2-2

info "Installing stock libfprint and dependencies..."
apt-get update -qq
apt-get install -y -qq --reinstall libfprint-2-2 libfprint-2-tod1 fprintd libpam-fprintd

info "Downloading ELAN TOD driver from Lenovo..."
curl -fsSL -o "$DRIVER_ZIP" "$DRIVER_URL"
echo "$DRIVER_SHA256  $DRIVER_ZIP" | sha256sum -c --quiet -
success "Driver checksum verified"
unzip -q -o "$DRIVER_ZIP" -d "$WORK_DIR"
unzip -q -o "$WORK_DIR"/libfprint-2-tod1-elan_*.zip -d "$WORK_DIR"

info "Installing ELAN TOD driver..."
install -D -m 644 "$WORK_DIR/$DRIVER_SO" "$TOD_DIR/$DRIVER_SO"
ldconfig

info "Reloading udev rules and restarting fprintd..."
udevadm control --reload-rules
udevadm trigger
systemctl restart fprintd.service

info "Enabling fingerprint authentication in PAM..."
pam-auth-update --enable fprintd

info "Cleaning up temporary files..."
rm -rf "$WORK_DIR"

info "Verifying device detection..."
if fprintd-list "$TARGET_USER" 2>&1 | grep -q "ELAN Fingerprint Sensor"; then
    success "ELAN fingerprint sensor is ready"
    info "Enroll your fingerprint via Settings > Users > Fingerprint Login"
    info "or run: fprintd-enroll"
else
    warn "ELAN TOD driver not picked up by fprintd — try rebooting"
fi
