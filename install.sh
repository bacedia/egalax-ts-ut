#!/bin/bash
set -e

echo "=== egalax-ts-ut kernel module installer ==="

if [ "$EUID" -ne 0 ]; then
    echo "Please run as root (sudo ./install.sh)"
    exit 1
fi

CONF="/etc/egalax-ts-ut.conf"

# Check for kernel headers
KVER=$(uname -r)
if [ ! -d "/lib/modules/${KVER}/build" ]; then
    echo "Kernel headers not found. Installing..."
    apt-get update -qq
    apt-get install -y -qq linux-headers-${KVER} build-essential
fi

# Check for inputattach and evtest
for pkg in inputattach evtest; do
    if ! command -v $pkg &>/dev/null; then
        echo "Installing $pkg..."
        apt-get install -y -qq $pkg
    fi
done

# Blacklist the old egalax_ts_serial module so it doesn't conflict
echo "Blacklisting egalax_ts_serial (mainline driver)..."
echo "blacklist egalax_ts_serial" > /etc/modprobe.d/egalax-ts-ut.conf

# Unload old module if loaded
rmmod egalax_ts_serial 2>/dev/null || true

# Build the module
echo "Building kernel module..."
make clean
make

# Install via DKMS for kernel upgrade persistence
if command -v dkms &>/dev/null; then
    echo "Installing via DKMS..."
    DKMS_VER="1.0.0"
    DKMS_DIR="/usr/src/egalax-ts-ut-${DKMS_VER}"
    mkdir -p "${DKMS_DIR}"
    cp egalax_ts_ut.c Makefile dkms.conf "${DKMS_DIR}/"
    dkms remove egalax-ts-ut/${DKMS_VER} --all 2>/dev/null || true
    dkms add egalax-ts-ut/${DKMS_VER}
    dkms build egalax-ts-ut/${DKMS_VER}
    dkms install egalax-ts-ut/${DKMS_VER}
else
    echo "DKMS not found, installing module directly..."
    make install
fi

# Load the module
echo "Loading module..."
modprobe egalax_ts_ut || insmod ./egalax_ts_ut.ko

# Auto-detect serial port if no config exists
if [ ! -f "$CONF" ]; then
    echo ""
    echo "No configuration found. Running auto-detection..."
    echo ""
    bash "$(dirname "$0")/detect.sh"
else
    echo "Config already exists at $CONF, skipping detection."
fi

# Install systemd service
echo "Installing systemd service..."
cp "$(dirname "$0")/egalax-touch.service" /etc/systemd/system/egalax-touch.service
systemctl daemon-reload
systemctl enable egalax-touch.service
systemctl restart egalax-touch.service

echo ""
echo "=== Installation complete ==="
echo ""
echo "Touchscreen service is running."
echo ""
echo "  Config:       $CONF"
echo "  Service:      systemctl status egalax-touch.service"
echo "  Calibrate:    sudo ./calibrate.sh"
echo "  Re-detect:    sudo ./detect.sh"
