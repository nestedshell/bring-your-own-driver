#!/usr/bin/env python3
"""Tests 2 and 3: raster over BLE with credit flow control.

Test 2 uses standard ESC/POS only. Test 3 adds the vendor start and end commands from
third-party notes. Each test prints a different number of bars, so the paper shows which
ones worked:

  test 2: two full-width bars, then a half-width bar on the right
  test 3: three full-width bars, then a half-width bar on the left
"""
import asyncio
import sys
import time

from bleak import BleakClient, BleakScanner

REPLY = "0000ff01-0000-1000-8000-00805f9b34fb"
WRITE = "0000ff02-0000-1000-8000-00805f9b34fb"
FLOW = "0000ff03-0000-1000-8000-00805f9b34fb"
WIDTH_BYTES = 48
BAR = b"\xff" * WIDTH_BYTES
GAP = b"\x00" * WIDTH_BYTES
HALF_LEFT = b"\xff" * 24 + b"\x00" * 24
HALF_RIGHT = b"\x00" * 24 + b"\xff" * 24


def raster(bars: int, half: bytes) -> bytes:
    rows = []
    for _ in range(bars):
        rows += [BAR] * 20 + [GAP] * 8
    rows += [half] * 20
    body = b"".join(rows)
    height = len(rows)
    return bytes([0x1D, 0x76, 0x30, 0x00, WIDTH_BYTES, 0x00, height & 0xFF, height >> 8]) + body


class Link:
    def __init__(self, client: BleakClient):
        self.client = client
        self.credits = 0
        self.packet = 20
        self.granted = 0
        self.more = asyncio.Event()
        self.t0 = time.time()

    def on_flow(self, _, data: bytearray):
        if data and data[0] == 0x01 and len(data) >= 2:
            self.credits += data[1]
            self.granted += data[1]
            self.more.set()
        elif data and data[0] == 0x02 and len(data) >= 3:
            self.packet = data[1] | data[2] << 8
            print(f"  packet size {self.packet}")

    def on_reply(self, _, data: bytearray):
        raw = bytes(data)
        text = "".join(chr(b) if 32 <= b < 127 else "." for b in raw)
        print(f"  [{time.time() - self.t0:6.2f}s] reply {raw.hex(' ')} |{text}|")

    async def send(self, data: bytes):
        sent = 0
        for i in range(0, len(data), self.packet):
            while self.credits <= 0:
                self.more.clear()
                await asyncio.wait_for(self.more.wait(), timeout=15)
            self.credits -= 1
            await self.client.write_gatt_char(WRITE, data[i : i + self.packet], response=False)
            sent += 1
        print(f"  sent {len(data)} bytes in {sent} packets, credits left {self.credits}")


async def main() -> int:
    device = await BleakScanner.find_device_by_filter(
        lambda d, adv: (adv.local_name or d.name or "").startswith("PPS1"), timeout=12.0
    )
    if device is None:
        print("printer not found")
        return 1
    async with BleakClient(device) as client:
        link = Link(client)
        await client.start_notify(REPLY, link.on_reply)
        await client.start_notify(FLOW, link.on_flow)
        await asyncio.sleep(1.0)
        print(f"connected, credits={link.credits}, packet={link.packet}")

        print("test 2: standard raster only")
        await link.send(raster(2, HALF_RIGHT) + bytes([0x1B, 0x4A, 60]))
        await asyncio.sleep(5)

        print("test 3: vendor start and end around the raster")
        await link.send(bytes(12) + bytes.fromhex("10 FF F1 03"))
        await link.send(raster(3, HALF_LEFT) + bytes([0x1B, 0x4A, 80]))
        await link.send(bytes.fromhex("10 FF F1 45"))
        await asyncio.sleep(8)
        print(f"total credits granted: {link.granted}")
    return 0


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
