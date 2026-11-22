#!/usr/bin/env python3
"""Test 4: what moves the paper between jobs?

Hypothesis: on tests 2 and 3 the feed between jobs did not show, and the second job overlapped
the first by about 26 rows. Five groups of thin bars are printed, each with a different count,
so the gaps on paper show the effect of each step:

  group 1 -> 2: feed only, standard commands
  group 2 -> 3: feed, then the vendor start command
  group 3 -> 4: feed, vendor end, vendor start
  group 4 -> 5: feed, vendor end, then standard commands only
"""
import asyncio
import sys

from bleak import BleakClient, BleakScanner

from test_print_ble import FLOW, GAP, BAR, REPLY, WIDTH_BYTES, Link

START = bytes(12) + bytes.fromhex("10 FF F1 03")
END = bytes.fromhex("10 FF F1 45")
FEED_60 = bytes([0x1B, 0x4A, 60])


def bars(count: int) -> bytes:
    rows = []
    for _ in range(count):
        rows += [BAR] * 12 + [GAP] * 6
    height = len(rows)
    return bytes([0x1D, 0x76, 0x30, 0x00, WIDTH_BYTES, 0x00, height & 0xFF, height >> 8]) + b"".join(rows)


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

        print("group 1: standard")
        await link.send(bars(1) + FEED_60)
        await asyncio.sleep(5)

        print("group 2: standard")
        await link.send(bars(2) + FEED_60)
        await asyncio.sleep(5)

        print("group 3: vendor start, then vendor end")
        await link.send(START + bars(3) + FEED_60 + END)
        await asyncio.sleep(5)

        print("group 4: vendor start, then vendor end")
        await link.send(START + bars(4) + FEED_60 + END)
        await asyncio.sleep(5)

        print("group 5: standard, with a long final feed")
        await link.send(bars(5) + bytes([0x1B, 0x4A, 120]))
        await asyncio.sleep(6)
    return 0


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
