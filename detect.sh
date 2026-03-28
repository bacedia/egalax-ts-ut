#!/bin/bash
#
# Auto-detect eGalax UT touchscreen serial port
#
# Scans ttyS0–15 for UT (0x55 0x54) packets and writes the result
# to /etc/egalax-ts-ut.conf.
#
# Usage: sudo ./detect.sh

set -e

CONF="/etc/egalax-ts-ut.conf"
BAUD=9600

if [ "$EUID" -ne 0 ]; then
    echo "Please run as root (sudo ./detect.sh)"
    exit 1
fi

echo "=== eGalax UT Touchscreen Port Detection ==="
echo ""
echo "Scanning /dev/ttyS0 through /dev/ttyS15."
echo "Tap the touchscreen repeatedly during the scan."
echo ""

FOUND=""

for i in $(seq 0 15); do
    port="/dev/ttyS${i}"
    [ -e "$port" ] || continue

    printf "  Scanning %-15s " "$port..."
    stty -F "$port" "$BAUD" raw -echo -crtscts -ixon -ixoff 2>/dev/null || { echo "skip"; continue; }
    data=$(timeout 2 cat "$port" 2>/dev/null | xxd -p | head -c 200)

    if echo "$data" | grep -q "5554"; then
        echo "FOUND"
        FOUND="$port"
        break
    else
        echo "no data"
    fi
done

if [ -z "$FOUND" ]; then
    echo ""
    echo "ERROR: No eGalax UT touchscreen found."
    echo ""
    echo "Make sure you were tapping the screen during the scan."
    echo "You can also specify the port manually in $CONF:"
    echo ""
    echo "  PORT=/dev/ttyS4"
    echo "  BAUD=9600"
    exit 1
fi

echo ""
echo "Detected eGalax UT touchscreen on $FOUND"
echo ""

cat > "$CONF" << EOF
# eGalax UT touchscreen configuration
# Auto-detected on $(date -Iseconds)
PORT=$FOUND
BAUD=$BAUD
EOF

echo "Config written to $CONF"
