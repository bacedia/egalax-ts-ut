#!/bin/bash
#
# Calibration helper for egalax-ts-ut
#
# Captures corner taps via evtest, calculates a libinput calibration
# matrix, and optionally installs it as a persistent X11 config.
#
# Usage: sudo ./calibrate.sh [event_device]
#   e.g. sudo ./calibrate.sh /dev/input/event3

set -e

DEVICE="${1:-}"

if [ "$EUID" -ne 0 ]; then
    echo "Please run as root (sudo ./calibrate.sh)"
    exit 1
fi

if ! command -v evtest &>/dev/null; then
    echo "Installing evtest..."
    apt-get install -y -qq evtest
fi

# Auto-detect device if not specified
if [ -z "$DEVICE" ]; then
    DEVICE=$(grep -l "eGalaxTouch Serial TouchScreen (UT)" /sys/class/input/event*/device/name 2>/dev/null | head -1 | sed 's|/sys/class/input/\(event[0-9]*\)/.*|/dev/input/\1|')
    if [ -z "$DEVICE" ]; then
        echo "ERROR: Could not find eGalax UT touchscreen device."
        echo "Make sure the module is loaded and inputattach is running."
        exit 1
    fi
fi

echo "Using device: $DEVICE"
echo ""
echo "This will ask you to tap each corner of the screen."
echo "Press and HOLD each corner firmly for 2-3 seconds, then release."
echo ""

capture_corner() {
    local corner_name="$1"
    echo ">>> Tap and HOLD the $corner_name corner, then release..."

    local x_sum=0 y_sum=0 count=0
    local got_touch=0

    while IFS= read -r line; do
        if echo "$line" | grep -q "BTN_TOUCH.*value 1"; then
            got_touch=1
        fi
        if [ $got_touch -eq 1 ]; then
            local x_val=$(echo "$line" | grep "ABS_X" | grep -o "value [0-9]*" | awk '{print $2}')
            local y_val=$(echo "$line" | grep "ABS_Y" | grep -o "value [0-9]*" | awk '{print $2}')
            if [ -n "$x_val" ]; then
                x_sum=$((x_sum + x_val))
                count=$((count + 1))
            fi
            if [ -n "$y_val" ]; then
                y_sum=$((y_sum + y_val))
            fi
        fi
        if echo "$line" | grep -q "BTN_TOUCH.*value 0" && [ $got_touch -eq 1 ]; then
            break
        fi
    done < <(timeout 15 evtest "$DEVICE" 2>/dev/null)

    if [ $count -eq 0 ]; then
        echo "ERROR: No touch data received for $corner_name. Try again."
        exit 1
    fi

    local x_avg=$((x_sum / count))
    local y_avg=$((y_sum / count))
    echo "    $corner_name: X=$x_avg Y=$y_avg ($count samples)"
    eval "${2}_X=$x_avg"
    eval "${2}_Y=$y_avg"
}

capture_corner "TOP-LEFT" TL
capture_corner "TOP-RIGHT" TR
capture_corner "BOTTOM-LEFT" BL
capture_corner "BOTTOM-RIGHT" BR

echo ""
echo "=== Raw Coordinates ==="
echo "  Top-left:     X=$TL_X  Y=$TL_Y"
echo "  Top-right:    X=$TR_X  Y=$TR_Y"
echo "  Bottom-left:  X=$BL_X  Y=$BL_Y"
echo "  Bottom-right: X=$BR_X  Y=$BR_Y"

# Get the max range from the device
MAX_RANGE=$(grep -A3 "ABS_X" /sys/class/input/$(basename $(dirname $(readlink -f /sys/class/input/$(basename $DEVICE)/device)))/capabilities/abs 2>/dev/null | head -1)
# Default to 16384 if we can't read it
RANGE=16384

# Calculate calibration matrix
# X: min/max from left/right edges
X_MIN=$(( (TL_X + BL_X) / 2 ))
X_MAX=$(( (TR_X + BR_X) / 2 ))

# Y: detect inversion (if top Y > bottom Y, Y is inverted)
Y_TOP=$(( (TL_Y + TR_Y) / 2 ))
Y_BOT=$(( (BL_Y + BR_Y) / 2 ))

if [ $Y_TOP -gt $Y_BOT ]; then
    Y_INVERTED=1
    Y_MIN=$Y_BOT
    Y_MAX=$Y_TOP
else
    Y_INVERTED=0
    Y_MIN=$Y_TOP
    Y_MAX=$Y_BOT
fi

# Calculate matrix values using awk for floating point
MATRIX=$(awk -v xmin=$X_MIN -v xmax=$X_MAX -v ymin=$Y_MIN -v ymax=$Y_MAX -v r=$RANGE -v yinv=$Y_INVERTED 'BEGIN {
    a = r / (xmax - xmin)
    c = -xmin / (xmax - xmin)
    if (yinv) {
        e = -r / (ymax - ymin)
        f = ymax / (ymax - ymin)
    } else {
        e = r / (ymax - ymin)
        f = -ymin / (ymax - ymin)
    }
    printf "%.6f 0 %.6f 0 %.6f %.6f 0 0 1", a, c, e, f
}')

echo ""
echo "=== Calibration Matrix ==="
echo "  $MATRIX"
echo ""
echo "Y axis inverted: $([ $Y_INVERTED -eq 1 ] && echo 'yes' || echo 'no')"
echo ""

# Apply immediately
DISPLAY=:0 XAUTHORITY=/home/*/.[Xx]authority xinput set-prop "EETI eGalaxTouch Serial TouchScreen (UT)" "libinput Calibration Matrix" $MATRIX 2>/dev/null && echo "Applied to current session." || echo "Could not apply to current session (X not running?)."

echo ""
read -p "Save as persistent X11 config? [Y/n] " SAVE
if [ "$SAVE" != "n" ] && [ "$SAVE" != "N" ]; then
    mkdir -p /etc/X11/xorg.conf.d
    cat > /etc/X11/xorg.conf.d/99-egalax-calibration.conf << XEOF
Section "InputClass"
    Identifier "eGalax UT Touchscreen"
    MatchProduct "EETI eGalaxTouch Serial TouchScreen (UT)"
    Option "CalibrationMatrix" "$MATRIX"
EndSection
XEOF
    echo "Saved to /etc/X11/xorg.conf.d/99-egalax-calibration.conf"
    echo "Will take effect on next X restart."
fi

echo ""
echo "Done."
