"""Wire protocol of the NETUM XL-P801X A4 thermal printer (reverse engineered).

The printer speaks a small ESC/POS subset over BLE. It has no text fonts, so every
page is sent as a 1-bit raster image with ``GS v 0``.

Print head: 1728 dots (216 mm at 203 dpi). Paper sits centred on the head: an A4
sheet (210 mm) covers 1680 dots and starts at dot 24.
"""

from __future__ import annotations

from dataclasses import dataclass

HEAD_DOTS = 1728
BYTES_PER_LINE = HEAD_DOTS // 8
DPMM = 8  # 203 dpi


@dataclass(frozen=True)
class Paper:
    name: str
    width_mm: float
    height_mm: float | None  # None: continuous roll, pages are not split

    @property
    def width(self) -> int:
        return min(HEAD_DOTS, round(self.width_mm * DPMM))

    @property
    def height(self) -> int | None:
        return round(self.height_mm * DPMM) if self.height_mm else None

    def offset(self, shift_mm: float = 0) -> int:
        """First head dot under the paper; ``shift_mm`` nudges it right (+) or left (-)."""
        centred = (HEAD_DOTS - self.width) // 2
        return max(0, min(HEAD_DOTS - self.width, centred + round(shift_mm * DPMM)))


PAPERS = {
    "a4": Paper("A4", 210, 297),
    "letter": Paper("US Letter", 215.9, 279.4),
    "a5": Paper("A5", 148, 210),
    "a6": Paper("A6", 105, 148),
    "80mm": Paper("80 mm roll", 80, None),
    "57mm": Paper("57 mm roll", 57, None),
}
DEFAULT_PAPER = "a4"

# BLE GATT (service 0xFF00)
SERVICE = "0000ff00-0000-1000-8000-00805f9b34fb"
WRITE_CHAR = "0000ff02-0000-1000-8000-00805f9b34fb"
# Credit flow control: 01 nn = +nn packets allowed, 02 lo hi = max packet size.
# Never subscribe to 0xFF01 (status): the firmware then stops returning credits.
FLOW_CHAR = "0000ff03-0000-1000-8000-00805f9b34fb"
NAME_PREFIX = "XL-P801"
PACKET_SIZE = 180

ESC_INIT = b"\x1b@"
BAND_ROWS = 256  # rows per GS v 0 block

DENSITY_MAX = 31
DENSITY_DEFAULT = 24


def set_density(level: int) -> bytes:
    """DC2 # n: the low 5 bits are the heat level (0 = faintest, 31 = darkest)."""
    return b"\x12\x23" + bytes([max(0, min(DENSITY_MAX, level))])


def feed(lines: int) -> bytes:
    """ESC d n: feed n text lines (about 3.75 mm each)."""
    return b"\x1bd" + bytes([max(0, min(255, lines))])


def raster_block(rows: bytes, width_bytes: int = BYTES_PER_LINE) -> bytes:
    """GS v 0 with packed rows, MSB = leftmost dot, 1 = black."""
    height = len(rows) // width_bytes
    header = b"\x1dv0\x00" + width_bytes.to_bytes(2, "little") + height.to_bytes(2, "little")
    return header + rows


def build_job(pages: list[bytes], density: int = DENSITY_DEFAULT, tail_feed: int = 4) -> bytes:
    """Concatenate full-width packed 1-bit pages into one print job."""
    job = bytearray(ESC_INIT + set_density(density))
    band = BYTES_PER_LINE * BAND_ROWS
    for page in pages:
        for i in range(0, len(page), band):
            job += raster_block(page[i : i + band])
    job += feed(tail_feed)
    return bytes(job)
