#!/bin/bash
set -e

echo "=== egalax-ts-ut kernel module installer ==="

if [ "$EUID" -ne 0 ]; then
    echo "Please run as root (sudo ./install.sh)"
    exit 1
fi

# Check for kernel headers
KVER=$(uname -r)
if [ ! -d "/lib/modules/${KVER}/build" ]; then
    echo "Kernel headers not found. Installing..."
    apt-get update -qq
    apt-get install -y -qq linux-headers-${KVER} build-essential
fi

# Check for inputattach
if ! command -v inputattach &>/dev/null; then
    echo "Installing inputattach..."
    apt-get install -y -qq inputattach
fi

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

echo ""
echo "=== Module installed ==="
echo ""
echo "To bind the touchscreen:"
echo "  inputattach --eetiegalax --baud 9600 /dev/ttyS4"
echo ""
echo "To make it start on boot, create a systemd service:"
echo "  See egalax-touch.service in this repo"
