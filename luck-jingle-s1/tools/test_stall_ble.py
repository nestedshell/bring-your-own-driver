#!/usr/bin/env python3
"""Test 7: does a pause in the data make a gap, and what ends an unfinished raster?

Part 1, one raster of 480 rows with pauses of 0.2, 0.5 and 1.0 s after rows 120, 240 and 360. The
lines run the whole length, so any paper movement shows as a break.

Part 2, a raster promising 300 rows stops after 80 rows, then the link closes. After a reconnect a
short labelled job follows. A readable label and an OK mean that closing the link ended the raster.

Part 3, the same stop with the link left open for 3 s, then a labelled job.

Part 4, a fresh link left idle for 20 s, then one raster of 480 rows with every packet timed. This is
closer to the web print, where the link is open for a while before a job starts.
"""
import asyncio
import sys
import time

from bleak import BleakClient, BleakScanner
from PIL import Image, ImageDraw, ImageFont

from test_print_ble import FLOW, REPLY, WIDTH_BYTES, WRITE, Link

WIDTH = WIDTH_BYTES * 8


def strip(rows: int, label: str, step: int = 40) -> bytes:
    image = Image.new("1", (WIDTH, rows), 1)
    draw = ImageDraw.Draw(image)
    for x in (0, WIDTH // 2 - 2, WIDTH - 6):
        draw.rectangle([x, 0, x + 5, rows - 1], fill=0)
    for y in range(0, rows, step):
        draw.rectangle([0, y, WIDTH - 1, y + 1], fill=0)
    draw.text((20, 6), label, font=ImageFont.load_default(size=30), fill=0)
    return bytes(b ^ 0xFF for b in image.tobytes())


def header(rows: int) -> bytes:
    return bytes([0x1D, 0x76, 0x30, 0x00, WIDTH_BYTES, 0x00, rows & 0xFF, rows >> 8])


def feed(dots: int) -> bytes:
    return bytes([0x1B, 0x4A, dots])


class CountingLink(Link):
    oks = 0

    def on_reply(self, sender, data):
        if b"OK" in bytes(data):
            self.oks += 1
        super().on_reply(sender, data)


async def timed_send(link: Link, data: bytes) -> None:
    """Sends like Link.send and reports the longest waits between packets."""
    stamps = []
    for i in range(0, len(data), link.packet):
        while link.credits <= 0:
            link.more.clear()
            await asyncio.wait_for(link.more.wait(), timeout=15)
        link.credits -= 1
        await link.client.write_gatt_char(WRITE, data[i : i + link.packet], response=False)
        stamps.append((time.monotonic(), i))
    gaps = sorted(((b[0] - a[0], b[1]) for a, b in zip(stamps, stamps[1:])), reverse=True)[:5]
    total = stamps[-1][0] - stamps[0][0]
    print(f"  {len(data)} bytes in {total:.2f} s, {len(stamps)} packets; longest waits:")
    for gap, offset in gaps:
        print(f"    {gap * 1000:6.0f} ms before byte {offset} (row {offset // WIDTH_BYTES})")


async def open_link(client: BleakClient) -> CountingLink:
    link = CountingLink(client)
    await client.start_notify(REPLY, link.on_reply)
    await client.start_notify(FLOW, link.on_flow)
    await asyncio.sleep(1.0)
    return link


async def find():
    return await BleakScanner.find_device_by_filter(
        lambda d, adv: (adv.local_name or d.name or "").startswith("PPS1"), timeout=15.0
    )


async def labelled_job(link: CountingLink, label: str) -> None:
    """Prints a labelled strip. With no OK the old raster was still open, so white rows complete it."""
    before = link.oks
    body = strip(80, label)
    await link.send(header(80) + body + feed(40))
    await asyncio.sleep(4)
    if link.oks > before:
        print(f"  {label}: OK, the old raster had ended")
        return
    print(f"  {label}: no OK, the old raster was still open; completing it")
    await link.send(bytes(220 * WIDTH_BYTES - len(body) - 11))
    await link.send(feed(40))
    await asyncio.sleep(4)


async def main() -> int:
    device = await find()
    if device is None:
        print("printer not found")
        return 1
    async with BleakClient(device) as client:
        link = await open_link(client)
        print("part 1: pauses inside one raster")
        rows = strip(480, "1 pauses")
        await link.send(header(480))
        for start, pause in ((0, 0.2), (120, 0.5), (240, 1.0), (360, 0)):
            await link.send(rows[start * WIDTH_BYTES : (start + 120) * WIDTH_BYTES])
            await asyncio.sleep(pause)
        await link.send(feed(60))
        await asyncio.sleep(5)

        print("part 2: stop after 80 of 300 rows, close the link")
        await link.send(header(300) + strip(80, "2 stopped"))
        await asyncio.sleep(1.0)
    await asyncio.sleep(3)

    device = await find()
    if device is None:
        print("printer not found after closing the link")
        return 1
    async with BleakClient(device) as client:
        link = await open_link(client)
        print("  after reconnect")
        await labelled_job(link, "2 after link closed")

        print("part 3: stop after 80 of 300 rows, link stays open")
        await link.send(header(300) + strip(80, "3 stopped"))
        await asyncio.sleep(3.0)
        print("  new job on the same link")
        await labelled_job(link, "3 after pause")
    await asyncio.sleep(3)

    device = await find()
    if device is None:
        print("printer not found before part 4")
        return 1
    async with BleakClient(device) as client:
        link = await open_link(client)
        print("part 4: link idle for 20 s, then one raster")
        await asyncio.sleep(20)
        await timed_send(link, header(480) + strip(480, "4 after idle") + feed(60))
        await asyncio.sleep(5)
    return 0


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
