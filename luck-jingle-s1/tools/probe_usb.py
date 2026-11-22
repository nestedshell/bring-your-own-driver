#!/usr/bin/env python3
"""Ask the S1 who it is over its USB serial port. Sends queries only, never print data."""
import glob
import sys
import time

import serial

QUERIES = [
    ("model", "10 FF 20 F0"),
    ("firmware", "10 FF 20 F1"),
    ("serial", "10 FF 20 F2"),
    ("battery", "10 FF 50 F1"),
    ("status", "10 FF 40"),
    ("density", "10 FF 11"),
    ("auto_off", "10 FF 13"),
    ("all_info", "10 FF 70"),
]


def show(data: bytes) -> str:
    text = "".join(chr(b) if 32 <= b < 127 else "." for b in data)
    return f"{data.hex(' ')}  |{text}|" if data else "(no reply)"


def main() -> int:
    ports = sys.argv[1:] or glob.glob("/dev/cu.usbmodem*")
    if not ports:
        print("No USB serial port found. Is the printer on and connected?")
        return 1
    with serial.Serial(ports[0], 115200, timeout=0.2) as port:
        print(f"port: {ports[0]}")
        time.sleep(0.3)
        print(f"on open: {show(port.read(256))}")
        for name, command in QUERIES:
            port.write(bytes.fromhex(command))
            port.flush()
            deadline = time.time() + 1.0
            reply = b""
            while time.time() < deadline:
                reply += port.read(256)
                if reply and not port.in_waiting:
                    time.sleep(0.1)
                    if not port.in_waiting:
                        break
            print(f"{name:9} {command:12} -> {show(reply)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
