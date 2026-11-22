#!/usr/bin/env python3
"""Test 1: can a standard ESC/POS raster command print over USB serial, with no vendor command?

Prints a short strip of about 12 mm: a solid bar, vertical stripes, and a half-width bar.
"""
import glob
import sys
import time

import serial

WIDTH_BYTES = 48  # hypothesis: 384 dots across, to be confirmed on paper


def strip() -> bytes:
    rows = []
    rows += [b"\xff" * WIDTH_BYTES] * 24
    rows += [b"\x00" * WIDTH_BYTES] * 8
    rows += [b"\xf0" * WIDTH_BYTES] * 24
    rows += [b"\x00" * WIDTH_BYTES] * 8
    rows += [b"\xff" * (WIDTH_BYTES // 2) + b"\x00" * (WIDTH_BYTES // 2)] * 24
    return b"".join(rows), len(rows)


def main() -> int:
    ports = sys.argv[1:] or glob.glob("/dev/cu.usbmodem*")
    if not ports:
        print("No USB serial port found.")
        return 1
    raster, height = strip()
    header = bytes([0x1D, 0x76, 0x30, 0x00, WIDTH_BYTES, 0x00, height & 0xFF, height >> 8])
    feed = bytes([0x1B, 0x4A, 80])
    with serial.Serial(ports[0], 115200, timeout=0.3) as port:
        port.write(header + raster + feed)
        port.flush()
        print(f"sent {len(header) + len(raster) + len(feed)} bytes on {ports[0]}")
        time.sleep(3)
        reply = port.read(256)
        print("reply:", reply.hex(" ") if reply else "(none)", reply[:40] if reply else "")
    return 0


if __name__ == "__main__":
    sys.exit(main())
