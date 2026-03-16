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

DRIVER_URL="https://download.lenovo.com/pccbbs/mobiles/r1slm02w.zip"
DRIVER_ZIP="/tmp/r1slm02w.zip"
EXTRACT_DIR="/tmp/fpc_fingerprint_driver"
LIB_DIR="/usr/lib/x86_64-linux-gnu"

if ! lsusb | grep -q "10a5:9800"; then
    error "FPC fingerprint sensor (10a5:9800) not found"
    error "This script is for Lenovo ThinkPad E14/E15 Gen 4 with FPC sensor"
    exit 1
fi
success "FPC fingerprint sensor detected"

info "Installing dependencies..."
apt-get install -y -qq libfprint-2-tod1 fprintd libpam-fprintd

info "Downloading FPC driver from Lenovo..."
curl -fsSL -o "$DRIVER_ZIP" "$DRIVER_URL"
mkdir -p "$EXTRACT_DIR"
unzip -o "$DRIVER_ZIP" -d "$EXTRACT_DIR"

info "Installing FPC proprietary library..."
cp "$EXTRACT_DIR/FPC_driver_linux_27.26.23.39/install_fpc/libfpcbep.so" "$LIB_DIR/"

info "Installing custom libfprint with FPC support..."
cp -r "$EXTRACT_DIR/FPC_driver_linux_libfprint/install_libfprint/lib/"* /lib/
cp -r "$EXTRACT_DIR/FPC_driver_linux_libfprint/install_libfprint/usr/"* /usr/
mkdir -p /var/log/fpc
chmod 755 "$LIB_DIR/libfprint-2.so.2.0.0"

info "Holding libfprint-2-2 package to prevent apt from overwriting..."
echo "libfprint-2-2 hold" | dpkg --set-selections

info "Reloading udev rules and restarting fprintd..."
udevadm control --reload-rules
udevadm trigger
systemctl restart fprintd.service

info "Cleaning up temporary files..."
rm -rf "$DRIVER_ZIP" "$EXTRACT_DIR"

info "Verifying device detection..."
if fprintd-list "$(logname)" 2>&1 | grep -q "FPC Sensor Controller"; then
    success "FPC fingerprint sensor is ready"
    info "Enroll your fingerprint via Settings > Users > Fingerprint Login"
    info "or run: fprintd-enroll"
else
    warn "Device not detected by fprintd — try rebooting"
fi
