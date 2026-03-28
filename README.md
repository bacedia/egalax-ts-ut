# egalax-ts-ut

Linux kernel module for eGalax serial touchscreen controllers using the 10-byte UT-prefixed binary protocol.

## Background

Many POS terminals (FlyTech, Touch Dynamic, Posiflex, etc.) use eGalax resistive touchscreens connected via internal RS-232 serial ports. These controllers use a 10-byte binary protocol with `UT` (0x55 0x54) sync headers that is **incompatible** with the mainline `egalax_ts_serial` kernel driver, which expects 5/6-byte packets with bit-7 start framing.

This out-of-tree kernel module correctly handles the UT protocol variant, providing a proper input device via the kernel's serio/input subsystems.

## Protocol

```
Byte 0:   0x55 ('U') ─┐ sync header
Byte 1:   0x54 ('T') ─┘
Byte 2:   Status — bit 0: touch down, bit 1: move, bit 2: touch up
Byte 3-4: X coordinate (little-endian uint16, range 0–16384)
Byte 5-6: Y coordinate (little-endian uint16, range 0–16384)
Byte 7-8: Z/pressure  (little-endian uint16)
Byte 9:   Checksum
```

## Why not the mainline driver?

The mainline `egalax_ts_serial` module (in `drivers/input/touchscreen/`) handles a different packet format:

| | Mainline `egalax_ts_serial` | This module (`egalax_ts_ut`) |
|---|---|---|
| Packet size | 5 or 6 bytes | 10 bytes |
| Sync/framing | Bit 7 of first byte | 0x55 0x54 ("UT") header |
| Coordinate encoding | 7-bit fields with shift | 16-bit little-endian |
| Result with UT controllers | Garbled coordinates, rapid BTN_TOUCH toggling | Correct operation |

Using the mainline driver with a UT-protocol controller produces unusable noise due to packet framing mismatch.

## Why not a userspace driver?

We tried. Extensively. Python (`os.open`, `serial.Serial`, subprocess pipes) and Rust (`libc::open`, `File::open`) all failed to reliably read from the serial port on ICH8M UARTs. The `O_NOCTTY` and `O_CLOEXEC` flags, Python buffering, and termios configuration via the tty layer all interfered with data flow. Only `cat` (which uses bare `O_RDONLY` and 128KB reads) could reliably read the port.

A kernel module bypasses the entire userspace tty layer and reads directly via the serio subsystem, which works reliably.

## Install

### Quick install

```bash
git clone https://github.com/bacedia/egalax-ts-ut.git
cd egalax-ts-ut
sudo ./install.sh
```

The install script:
- Installs kernel headers, build tools, inputattach, and evtest if needed
- Builds the module
- Installs via DKMS (auto-rebuilds on kernel upgrades)
- Blacklists the conflicting mainline `egalax_ts_serial` module
- Loads the module
- **Auto-detects the touchscreen serial port** (prompts you to tap the screen)
- Writes config to `/etc/egalax-ts-ut.conf`
- Installs and enables the systemd service

### Manual install

```bash
# Install dependencies
sudo apt install linux-headers-$(uname -r) build-essential inputattach evtest

# Build
make

# Load
sudo insmod egalax_ts_ut.ko

# Detect your serial port (tap the screen when prompted)
sudo ./detect.sh

# Or configure manually
echo -e "PORT=/dev/ttyS4\nBAUD=9600" | sudo tee /etc/egalax-ts-ut.conf

# Bind to serial port
sudo inputattach --eetiegalax --baud 9600 /dev/ttyS4
```

### Persist across reboots

```bash
# Install the systemd service
sudo cp egalax-touch.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now egalax-touch.service
```

## Configuration

Config file: `/etc/egalax-ts-ut.conf`

```
PORT=/dev/ttyS4
BAUD=9600
```

| Setting | Description |
|---|---|
| `PORT` | Serial port the touchscreen controller is on |
| `BAUD` | Baud rate (9600 is standard for most eGalax controllers) |

To re-detect the serial port:

```bash
sudo ./detect.sh
```

This scans `/dev/ttyS0` through `/dev/ttyS15` for UT packets while you tap the screen, and updates the config file.

## Calibration

The module reports raw coordinates (0–16384 range). Use the included calibration script to generate a libinput calibration matrix:

```bash
sudo ./calibrate.sh
```

This walks you through tapping each corner, calculates the matrix (with Y-inversion detection), applies it to the current session, and optionally saves it as a persistent X11 config at `/etc/X11/xorg.conf.d/99-egalax-calibration.conf`.

To calibrate manually:

```bash
xinput set-prop "EETI eGalaxTouch Serial TouchScreen (UT)" "libinput Calibration Matrix" <a> 0 <c> 0 <e> <f> 0 0 1
```

## Tested on

- FlyTech P495-C48 (POS 495) — Atom D525, ICH8M, Ubuntu 24.04 (kernel 6.17)
- eGalax resistive touchscreen on /dev/ttyS4

Should work on any system with an eGalax serial touch controller using the UT-prefixed protocol.

## License

GPL v2 (same as the Linux kernel). This module is derived from `egalax_ts_serial.c` by Zoltán Böszörményi, which is GPL v2 licensed.

## Author

Bailey Dickens
