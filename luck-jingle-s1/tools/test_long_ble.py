#!/usr/bin/env python3
"""Test 5: send an 80 mm page in 255-row blocks (A) and as one raster command (B).

Each page has three unbroken vertical lines and a tick every 10 mm. A blank band or a skip
shows as a break in the lines, and the ticks measure the real length on paper.
"""
import asyncio
import sys
import time

from bleak import BleakClient, BleakScanner
from PIL import Image, ImageDraw, ImageFont

from test_print_ble import FLOW, REPLY, WIDTH_BYTES, Link

ROWS = 640  # 80 mm at 8 dots per mm
WIDTH = WIDTH_BYTES * 8


def page(label: str) -> bytes:
    image = Image.new("1", (WIDTH, ROWS), 1)
    draw = ImageDraw.Draw(image)
    for x in (0, WIDTH // 2 - 2, WIDTH - 6):
        draw.rectangle([x, 0, x + 5, ROWS - 1], fill=0)
    for y in range(0, ROWS, 80):
        draw.rectangle([0, y, WIDTH - 1, y + 2], fill=0)
    font = ImageFont.load_default(size=44)
    for y in range(20, ROWS, 160):
        draw.text((24, y), label, font=font, fill=0)
        draw.text((WIDTH // 2 + 20, y), f"{y // 8} mm", font=ImageFont.load_default(size=26), fill=0)
    # PIL stores 1 for white; the printer burns 1 as black.
    return bytes(b ^ 0xFF for b in image.tobytes())


def command(rows: bytes) -> bytes:
    height = len(rows) // WIDTH_BYTES
    return bytes([0x1D, 0x76, 0x30, 0x00, WIDTH_BYTES, 0x00, height & 0xFF, height >> 8]) + rows


async def run(link: Link, label: str, blocks: list[bytes]) -> None:
    start = time.time()
    await link.send(b"".join(blocks) + bytes([0x1B, 0x4A, 100]))
    seconds = time.time() - start
    size = sum(len(b) for b in blocks)
    print(f"{label}: {size} bytes in {seconds:.1f} s = {size / seconds / 1024:.1f} kB/s")


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

        rows = page("A blocks")
        step = 255 * WIDTH_BYTES
        await run(link, "A, 255-row blocks", [command(rows[i : i + step]) for i in range(0, len(rows), step)])
        await asyncio.sleep(12)

        await run(link, "B, one command", [command(page("B single"))])
        await asyncio.sleep(12)
    return 0


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
