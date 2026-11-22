#!/usr/bin/env python3
"""Test 6: what makes the white gaps at raster block boundaries?

The first web print showed a gap at every 255-row boundary. Test 5 had shown none, but it differed
in two ways: a light page, and blocks joined so that a boundary fell inside a BLE packet. Four
pages of 400 rows (one boundary, at row 255), with a white tick every 10 mm, separate the causes:

  A dark,  blocks, each block starts a new packet (like the web driver)
  B dark,  blocks joined in one stream (like test 5)
  C light, blocks, each block starts a new packet
  D dark,  one raster command
"""
import asyncio
import sys
import time

from bleak import BleakClient, BleakScanner
from PIL import Image, ImageDraw, ImageFont

from test_print_ble import FLOW, REPLY, WIDTH_BYTES, Link

ROWS = 400
WIDTH = WIDTH_BYTES * 8


def page(label: str, dark: bool) -> bytes:
    ink, paper = (0, 1) if dark else (1, 0)  # PIL 1-bit: 0 is black
    image = Image.new("1", (WIDTH, ROWS), ink)
    draw = ImageDraw.Draw(image)
    for y in range(0, ROWS, 80):
        draw.rectangle([0, y, WIDTH - 1, y + 2], fill=paper)
    draw.text((24, 16), label, font=ImageFont.load_default(size=40), fill=paper)
    if not dark:
        draw.rectangle([0, 0, 5, ROWS - 1], fill=0)
        draw.rectangle([WIDTH - 6, 0, WIDTH - 1, ROWS - 1], fill=0)
    return bytes(b ^ 0xFF for b in image.tobytes())


def command(rows: bytes) -> bytes:
    height = len(rows) // WIDTH_BYTES
    return bytes([0x1D, 0x76, 0x30, 0x00, WIDTH_BYTES, 0x00, height & 0xFF, height >> 8]) + rows


def blocks(rows: bytes) -> list[bytes]:
    step = 255 * WIDTH_BYTES
    return [command(rows[i : i + step]) for i in range(0, len(rows), step)]


async def job(link: Link, name: str, pieces: list[bytes]) -> None:
    print(name)
    start = time.time()
    for piece in pieces:
        await link.send(piece)
        print(f"  {time.time() - start:5.1f} s")
    await link.send(bytes([0x1B, 0x4A, 60]))
    await asyncio.sleep(8)


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
        await job(link, "A dark, blocks, new packet", blocks(page("A dark new", True)))
        await job(link, "B dark, blocks, joined", [b"".join(blocks(page("B dark joined", True)))])
        await job(link, "C light, blocks, new packet", blocks(page("C light new", False)))
        await job(link, "D dark, one command", [command(page("D dark single", True))])
    return 0


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
