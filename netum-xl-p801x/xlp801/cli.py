"""Command line: print PDFs, images and text files on the XL-P801X."""

from __future__ import annotations

import argparse
import asyncio
import sys
import time
from pathlib import Path

from . import protocol, render
from .ble import Printer


def parse_pages(spec: str | None) -> set[int] | None:
    if not spec:
        return None
    pages: set[int] = set()
    for part in spec.split(","):
        a, _, b = part.partition("-")
        pages.update(range(int(a), int(b or a) + 1))
    return pages


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(prog="xlp801", description="Print on a NETUM XL-P801X A4 thermal printer over Bluetooth LE.")
    ap.add_argument("files", nargs="+", type=Path, help="PDF, image (png/jpg/...) or text file")
    ap.add_argument("-d", "--density", type=int, default=protocol.DENSITY_DEFAULT,
                    help=f"heat level 0-{protocol.DENSITY_MAX} (default {protocol.DENSITY_DEFAULT})")
    ap.add_argument("--dither", choices=["auto", "floyd", "atkinson", "threshold"], default="auto",
                    help="auto (default): crisp text, dithered greys")
    ap.add_argument("--paper", choices=list(protocol.PAPERS), default=protocol.DEFAULT_PAPER,
                    help="page size; content is scaled to its width and centred on the head (default a4)")
    ap.add_argument("-p", "--pages", help="PDF pages, e.g. 1-3,5")
    ap.add_argument("-m", "--margin", type=float, default=0, help="extra margin in mm (default 0)")
    ap.add_argument("-c", "--copies", type=int, default=1)
    ap.add_argument("--brightness", type=float, default=1.0)
    ap.add_argument("--contrast", type=float, default=1.0)
    ap.add_argument("--shift", type=float, default=0,
                    help="move the print right (+) or left (-) in mm, if the paper is not centred")
    ap.add_argument("--preview", type=Path, help="write a PNG preview of page 1 and do not print")
    ap.add_argument("--address", help="BLE address/UUID (default: first XL-P801X found)")
    args = ap.parse_args(argv)

    paper = protocol.PAPERS[args.paper]
    offset = paper.offset(args.shift)
    packed: list[bytes] = []
    for f in args.files:
        for img in render.load(f, paper, parse_pages(args.pages), args.margin):
            data, bw = render.to_head(img, args.dither, args.brightness, args.contrast, offset)
            if args.preview:
                bw.save(args.preview)
                print(f"Preview written to {args.preview}")
                return 0
            packed.append(data)
    if not packed:
        print("Nothing to print.", file=sys.stderr)
        return 1

    job = protocol.build_job(packed * args.copies, args.density)
    print(f"{len(packed) * args.copies} page(s), {len(job) / 1024:.0f} KB")
    return asyncio.run(_send(job, args.address))


async def _send(job: bytes, address: str | None) -> int:
    start = time.time()

    def progress(done: int, total: int) -> None:
        pct = done * 100 // total
        bar = "#" * (pct // 4)
        print(f"\r[{bar:<25}] {pct:3d}%  {done / 1024 / max(time.time() - start, 0.01):5.1f} KB/s", end="", flush=True)

    try:
        async with Printer(address) as printer:
            await printer.write(job, progress)
    except RuntimeError as e:
        print(f"\n{e}", file=sys.stderr)
        return 2
    print(f"\nSent in {time.time() - start:.0f}s")
    return 0


if __name__ == "__main__":
    sys.exit(main())
