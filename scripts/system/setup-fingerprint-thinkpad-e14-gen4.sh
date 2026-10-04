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

FPC_SENSOR_ID="10a5:9800"
ELAN_SENSOR_ID="04f3:0c4b"
DRIVER_URL="https://download.lenovo.com/pccbbs/mobiles/r1slm02w.zip"
DRIVER_SHA256="e725be53da4a6235b9621289386c44ecacb8d03a52c2d56d69904525fe6f7f3f"
LIB_DIR="/usr/lib/x86_64-linux-gnu"
TARGET_USER="${SUDO_USER:-$(logname)}"
WORK_DIR="$(mktemp -d)"
DRIVER_ZIP="$WORK_DIR/r1slm02w.zip"
EXTRACT_DIR="$WORK_DIR/fpc_fingerprint_driver"

if ! lsusb | grep -q "$FPC_SENSOR_ID"; then
    error "FPC fingerprint sensor ($FPC_SENSOR_ID) not found"
    error "This script is for Lenovo ThinkPad E14/E15 Gen 4 with FPC sensor"
    if lsusb | grep -q "$ELAN_SENSOR_ID"; then
        error "ELAN sensor ($ELAN_SENSOR_ID) detected — use setup-fingerprint-thinkpad-e14-gen3.sh instead"
    fi
    exit 1
fi
success "FPC fingerprint sensor detected"

info "Installing dependencies..."
apt-get install -y -qq libfprint-2-tod1 fprintd libpam-fprintd

info "Downloading FPC driver from Lenovo..."
curl -fsSL -o "$DRIVER_ZIP" "$DRIVER_URL"
echo "$DRIVER_SHA256  $DRIVER_ZIP" | sha256sum -c --quiet -
success "Driver checksum verified"
unzip -q -o "$DRIVER_ZIP" -d "$EXTRACT_DIR"

info "Installing FPC proprietary library..."
cp "$EXTRACT_DIR/FPC_driver_linux_27.26.23.39/install_fpc/libfpcbep.so" "$LIB_DIR/"

info "Installing custom libfprint with FPC support..."
cp -r "$EXTRACT_DIR/FPC_driver_linux_libfprint/install_libfprint/lib/"* /lib/
cp -r "$EXTRACT_DIR/FPC_driver_linux_libfprint/install_libfprint/usr/"* /usr/
mkdir -p /var/log/fpc
chmod 755 "$LIB_DIR/libfprint-2.so.2.0.0"
ldconfig

info "Holding libfprint-2-2 package to prevent apt from overwriting..."
apt-mark hold libfprint-2-2

info "Reloading udev rules and restarting fprintd..."
udevadm control --reload-rules
udevadm trigger
systemctl restart fprintd.service

info "Enabling fingerprint authentication in PAM..."
pam-auth-update --enable fprintd

info "Cleaning up temporary files..."
rm -rf "$WORK_DIR"

info "Verifying device detection..."
if fprintd-list "$TARGET_USER" 2>&1 | grep -q "FPC Sensor Controller"; then
    success "FPC fingerprint sensor is ready"
    info "Enroll your fingerprint via Settings > Users > Fingerprint Login"
    info "or run: fprintd-enroll"
else
    warn "Device not detected by fprintd — try rebooting"
fi
