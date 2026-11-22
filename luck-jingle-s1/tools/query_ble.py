#!/usr/bin/env python3
"""Ask the S1 who it is over BLE and log every notification. Sends queries only, never print data."""
import asyncio
import sys
import time

from bleak import BleakClient, BleakScanner

SERVICE_PREFIXES = ("PPS1", "S1_")
REPLY = "0000ff01-0000-1000-8000-00805f9b34fb"
WRITE = "0000ff02-0000-1000-8000-00805f9b34fb"
FLOW = "0000ff03-0000-1000-8000-00805f9b34fb"

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
    return f"{data.hex(' ')}  |{text}|"


async def main() -> int:
    device = await BleakScanner.find_device_by_filter(
        lambda d, adv: (adv.local_name or d.name or "").startswith(SERVICE_PREFIXES), timeout=10.0
    )
    if device is None:
        print("printer not found")
        return 1
    start = time.time()

    def logger(label):
        def handler(_, data: bytearray):
            print(f"  [{time.time() - start:6.2f}s] {label} <- {show(bytes(data))}")
        return handler

    async with BleakClient(device) as client:
        print(f"connected to {device.name}, mtu={client.mtu_size}")
        await client.start_notify(FLOW, logger("FF03"))
        await client.start_notify(REPLY, logger("FF01"))
        await asyncio.sleep(1.0)
        for name, command in QUERIES:
            print(f"-> {name:9} {command}")
            await client.write_gatt_char(WRITE, bytes.fromhex(command), response=False)
            await asyncio.sleep(0.8)
    return 0


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
