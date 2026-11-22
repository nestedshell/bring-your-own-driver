# NETUM XL-P801X — Bluetooth LE protocol

Reverse engineered on a unit advertising as `XL-P801X_0A03` (firmware unknown), October 2026.
Everything below was verified by printing, not taken from vendor documentation.

## Radio

The printer is dual mode. macOS lists the Classic side as `XL-P801X_xxxx`, with a keyboard icon because
the module reports a wrong Class of Device. You do not need to pair it. The BLE side advertises as
`XL-P801X_xxxx_LE`, with service UUIDs `e7810a71-…` and `0x18F0`, and manufacturer data `0x434B`.

| Service | Characteristic | Properties | Use |
|---|---|---|---|
| `0xFF00` | `0xFF02` | write, write-without-response | **print data** |
| | `0xFF01` | notify | status replies (e.g. to `ESC v`). **Do not subscribe** (see below). |
| | `0xFF03` | notify | **credit flow control** |
| `0x18F0` | `0x2AF1` / `0x2AF0` | write / notify | same command parser, generic "printer" service |
| `e7810a71-…` | `bef8d6c9-…` | write, notify | vendor (unused) |
| `49535343-fe7d-…` | ISSC transparent UART | write, notify | (unused) |

Negotiated ATT MTU on macOS is 247. The printer reports a maximum packet of 182 bytes. The driver uses 180.

### Credit flow control (`0xFF03`)

Right after subscribing, the printer sends:

- `01 0A`: 10 credits (each credit allows one write-without-response packet)
- `02 B6 00`: maximum packet size, 182 bytes (little-endian)

Then it sends `01 01` every time it has consumed a packet. Sending without credits overflows the
buffer and the printout is truncated.

Two quirks:

1. **If you subscribe to `0xFF01`, the printer never returns credits.** Leave that characteristic alone.
2. As a precaution, if no credit arrives for 2 s, the driver sends one more packet anyway. This was added
   while `0xFF01` was still subscribed; after that subscription was removed, no stall was observed.

Writes *with* response also work without credits (ATT-level flow control), but they are about twice as slow (~6 KB/s).
With credits a full A4 page (216 B × 2376 rows = 513,216 B) took 48 s, about 10.7 kB/s.

## Command set

The printer has **no fonts**: text sent as ESC/POS characters is ignored. Everything is printed as raster.

| Bytes | Meaning |
|---|---|
| `1B 40` | `ESC @` initialise. This also resets the darkness. |
| `12 23 n` | `DC2 # n` darkness. The low 5 bits are the heat level: 0 = faintest, 31 = darkest. Without the command, prints are faint (the power-on default was not measured). The driver sends 24. Public manuals for similar printers (CSN-A2 v4.0, p. 48) define D4..D0 as density and D7..D5 as heating break time; the upper bits were not tested here. |
| `1D 76 30 00 xL xH yL yH d…` | `GS v 0` raster, `x` = bytes per row (216), `y` = rows, MSB = leftmost dot, 1 = black |
| `1B 64 n` | `ESC d n` feed n lines |
| `1B 4A n` | `ESC J n` feed n dots |
| `1B 76` | `ESC v` status: replies `00` on the notify characteristic paired with the write channel |

Tested with no visible effect: `GS ( K` fn 49/50, `ESC 7`, `1F 11 02 n`, `10 FF 10 00 n`. No reply came to `DLE EOT n`, `GS I n` or `GS r`.

## Geometry

- The print head is **1728 dots** (216 mm at 203 dpi, 8 dots/mm).
- An A4 sheet (210 mm) covers dots **24 to 1704**. The first and last 24 dots print in the air.
- So an A4 page is 1680 × 2376 dots, sent as 1728-dot rows with a 24-dot left offset.
- The driver sends pages in `GS v 0` bands of 256 rows.
- Other paper sizes (A5, A6, rolls) are assumed to be centred on the head too, at `(1728 − width) / 2`.
  This was measured for A4 only; a shift setting corrects other paper guides.

## Image processing

A 1-bit head cannot print grey. The driver's default "auto" mode:

1. Finds edges: a dot whose 3×3 neighbourhood spans more than 96 grey levels.
2. Applies a hard threshold at 150 on edges, so text and lines stay sharp and slightly bold.
3. Applies Floyd–Steinberg dithering on flat areas, after a levels stretch (< 60 → black, > 200 → white).

Dithering the antialiased edges of glyphs makes text look fuzzy on this head. Step 2 avoids that.
