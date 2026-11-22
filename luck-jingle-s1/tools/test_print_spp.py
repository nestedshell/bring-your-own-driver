#!/usr/bin/env python3
"""Test: does the S1 print over its paired Classic Bluetooth serial port, and is that link encrypted?

Linux only (BlueZ sockets, no extra packages). The printer must already be paired with this computer.
Sends the same three things the drivers send over BLE: the read-only battery query, one GS v 0 raster
and one ESC J feed. Prints a strip of about 16 mm labelled "SPP" with the date.

Usage: test_print_spp.py <classic address> [--no-print]
"""
import array
import fcntl
import socket
import struct
import sys
import time

WIDTH_BYTES = 48  # 384 dots
SOL_BLUETOOTH, BT_SECURITY = 274, 4
BT_SECURITY_MEDIUM = 2  # the kernel refuses the channel unless the link is authenticated and encrypted
HCIGETCONNLIST = 0x800448D4
LINK_MODE = {0x0001: "CENTRAL", 0x0002: "AUTH", 0x0004: "ENCRYPT", 0x0008: "TRUSTED",
             0x0010: "RELIABLE", 0x0020: "SECURE", 0x0040: "FIPS"}
LINK_TYPE = {0: "SCO", 1: "ACL (classic)", 2: "eSCO", 0x80: "LE"}

FONT = {
    "S": ["01111", "10000", "10000", "01110", "00001", "00001", "11110"],
    "P": ["11110", "10001", "10001", "11110", "10000", "10000", "10000"],
    " ": ["00000"] * 7,
    "-": ["00000", "00000", "00000", "11111", "00000", "00000", "00000"],
    "0": ["01110", "10001", "10011", "10101", "11001", "10001", "01110"],
    "1": ["00100", "01100", "00100", "00100", "00100", "00100", "01110"],
    "2": ["01110", "10001", "00001", "00010", "00100", "01000", "11111"],
    "3": ["11111", "00010", "00100", "00010", "00001", "10001", "01110"],
    "4": ["00010", "00110", "01010", "10010", "11111", "00010", "00010"],
    "5": ["11111", "10000", "11110", "00001", "00001", "10001", "01110"],
    "6": ["00110", "01000", "10000", "11110", "10001", "10001", "01110"],
    "7": ["11111", "00001", "00010", "00100", "01000", "01000", "01000"],
    "8": ["01110", "10001", "10001", "01110", "10001", "10001", "01110"],
    "9": ["01110", "10001", "10001", "01111", "00001", "00010", "01100"],
}


def pack(bits):
    bits = (bits + [0] * (WIDTH_BYTES * 8))[: WIDTH_BYTES * 8]
    return bytes(sum(bits[i + j] << (7 - j) for j in range(8)) for i in range(0, len(bits), 8))


def label(text, scale=4):
    rows = []
    for y in range(7):
        bits = [0] * 8
        for ch in text:
            bits += [int(b) for b in FONT[ch][y] for _ in range(scale)] + [0] * scale
        rows += [pack(bits)] * scale
    return rows


def strip(text):
    rows = label(text)
    rows += [bytes(WIDTH_BYTES)] * 8
    rows += [b"\xff" * WIDTH_BYTES] * 16                       # solid bar
    rows += [bytes(WIDTH_BYTES)] * 8
    for y in range(48):                                         # diagonals: a lost byte breaks the lines
        rows.append(pack([1 if (x + y) % 32 < 3 else 0 for x in range(WIDTH_BYTES * 8)]))
    rows += [bytes(WIDTH_BYTES)] * 8
    rows += [b"\xff" * (WIDTH_BYTES // 2) + bytes(WIDTH_BYTES // 2)] * 12  # half bar: shows left and right
    return rows


def links():
    """Connections as the kernel reports them, with their link-mode flags. Needs no privileges."""
    hci = socket.socket(socket.AF_BLUETOOTH, socket.SOCK_RAW, socket.BTPROTO_HCI)
    buf = array.array("B", struct.pack("HH", 0, 16) + bytes(16 * 16))
    fcntl.ioctl(hci, HCIGETCONNLIST, buf, True)
    hci.close()
    _, count = struct.unpack_from("HH", buf, 0)
    out = []
    for i in range(count):
        handle, addr, kind, _out, state, mode = struct.unpack_from("H6sBBHI", buf, 4 + 16 * i)
        out.append((":".join(f"{b:02X}" for b in reversed(addr)), LINK_TYPE.get(kind, hex(kind)), handle,
                    " ".join(n for bit, n in LINK_MODE.items() if mode & bit) or "(no flags)"))
    return out


def read_for(sock, seconds):
    data, end = b"", time.time() + seconds
    while time.time() < end:
        try:
            data += sock.recv(256)
        except socket.timeout:
            pass
    return data


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 1
    address, do_print = sys.argv[1], "--no-print" not in sys.argv
    print("links before:", links() or "none")
    sock, channel = None, None
    for ch in range(1, 8):
        s = socket.socket(socket.AF_BLUETOOTH, socket.SOCK_STREAM, socket.BTPROTO_RFCOMM)
        s.setsockopt(SOL_BLUETOOTH, BT_SECURITY, struct.pack("BB", BT_SECURITY_MEDIUM, 0))
        s.settimeout(12)
        try:
            s.connect((address, ch))
            sock, channel = s, ch
            break
        except OSError as e:
            print(f"channel {ch}: {e}")
            s.close()
    if sock is None:
        print("no RFCOMM channel accepted the connection")
        return 1
    level = sock.getsockopt(SOL_BLUETOOTH, BT_SECURITY, 2)[0]
    print(f"connected on RFCOMM channel {channel}; socket security level {level} (2 = encryption required)")
    for row in links():
        print("link:", *row)
    sock.settimeout(0.3)
    stray = read_for(sock, 0.5)
    if stray:
        print("unsolicited:", stray.hex(" "))
    sock.send(bytes([0x10, 0xFF, 0x50, 0xF1]))
    reply = read_for(sock, 1.5)
    print("battery query reply:", reply.hex(" ") if reply else "(none)")
    if do_print:
        rows = strip(time.strftime("SPP %d-%m-%Y"))
        job = bytes([0x1D, 0x76, 0x30, 0x00, WIDTH_BYTES, 0x00, len(rows) & 0xFF, len(rows) >> 8])
        job += b"".join(rows) + bytes([0x1B, 0x4A, 80])
        start = time.time()
        sock.sendall(job)
        print(f"sent {len(job)} bytes, {len(rows)} rows, in {time.time() - start:.2f} s")
        reply = read_for(sock, 4)
        print("reply after print:", reply.hex(" ") if reply else "(none)", reply[:40] if reply else "")
    for row in links():
        print("link at end:", *row)
    sock.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
