# Dependencies

Everything the drivers use that this repository did not write, with the versions required and the versions last checked. Last reviewed: 21 November 2026.

## Python (command line and test programs)

Python 3.11 or later is needed, because Pillow 13 requires it. Apple's Python from the Command Line Tools is older, so on a Mac use Python from python.org or Homebrew.

| Package | Used by | Required | Checked | Licence | Notes |
| --- | --- | --- | --- | --- | --- |
| [bleak](https://pypi.org/project/bleak/) | `netum-xl-p801x/xlp801/`, `luck-jingle-s1/tools/` | `>=0.22` | 3.1.0 | MIT | Bluetooth LE. No published advisories. |
| [Pillow](https://pypi.org/project/pillow/) | both | `>=13.0.0` | 13.0.0 | MIT-CMU | Opens and converts images. The minimum was raised on 21 November 2026 to exclude versions with published security advisories. |
| [PyMuPDF](https://pypi.org/project/PyMuPDF/) | `netum-xl-p801x/xlp801/` (PDF files only) | `>=1.28.2,<2` | 1.28.2 (MuPDF 1.28.2) | AGPL-3.0 or Artifex commercial | Draws PDF pages. 1.28.2 includes a MuPDF later than the versions affected by the published PDF-parsing advisories. Kept below 2 because PyMuPDF 2.x also installs onnxruntime, numpy and the pymupdf4llm and pymupdf-layout packages, which the driver does not need. PyMuPDF 2.0 also fixes a problem in PyMuPDF's own command-line tool, which the driver does not use. |
| [pySerial](https://pypi.org/project/pyserial/) | `luck-jingle-s1/tools/probe_usb.py`, `luck-jingle-s1/tools/test_print_usb.py` | `>=3.5` | 3.5 | BSD-3-Clause | USB serial port (the Bluetooth serial test, `test_print_spp.py`, uses only the standard library). Latest release November 2020; no published advisories. |

The requirements are in `netum-xl-p801x/requirements.txt` and `luck-jingle-s1/requirements.txt`.

**Licences.** This repository is under the MIT licence and does not contain or redistribute PyMuPDF: it only names it as a dependency, installed by the user with `pip`. Anyone who distributes a package that includes PyMuPDF must follow the AGPL-3.0 for that package.

## Web pages

| Component | Used by | Version | Licence | Where |
| --- | --- | --- | --- | --- |
| [pdf.js](https://github.com/mozilla/pdf.js) | `netum-xl-p801x/web/`, `luck-jingle-s1/web/` | 6.5.438 | Apache-2.0 | `web/vendor/pdfjs/` in each folder |

pdf.js is served from the same folder as the page, so the pages load nothing from the internet. It replaces pdf.js 3.11.174, which the pages used to load from cdnjs and which is affected by [CVE-2024-4367](https://nvd.nist.gov/vuln/detail/CVE-2024-4367) (code run in the page when a crafted PDF is opened). No advisories are listed in [OSV](https://osv.dev/) for 6.5.438 as of 21 November 2026.

The files come from the npm package `pdfjs-dist@6.5.438`. The package's integrity value published by the npm registry was checked before extracting it: `sha512-vg8Pw1x+AFKy4AMDvhuWl5cOYV8d698UoEANoFFhc79hqXDnZQqnOXoxw3HG907WHOg1JYOvLhP756boddFxpA==`. SHA-256 of the copied files:

```
3a88402882cfa3e7e72c2c9b5149f52f0f88baf1c5b62aa11a41abdbc2072440  pdf.min.mjs
1e64c8240e54735ec5913b37acd5134747799cb8c6bb3777c70adbc01232d2aa  pdf.worker.min.mjs
466f45c2a61a698152fb5400c27e56ff2ceb73dcb71fde3fc366a502308eaab0  wasm/jbig2.wasm
7ea4b2b04613370ad4e9c1162da750cc88b4b176eac0d0c164b3caff23fc0a46  wasm/openjpeg.wasm
663d86126d5f5fcb1c61490f94353e2a8375660b8c5498ab3ebab5a34b08800e  wasm/qcms_bg.wasm
70150223396487e1ccfef7eac61fc780074ad7fcc9e843b702a8a3bc23107494  wasm/jbig2_nowasm_fallback.js
2855f1590e7fd7abbbf204cd13a5c09d30c92fe2c9313fb72b64aa763fe8b4f3  wasm/openjpeg_nowasm_fallback.js
```

The XL-P801X page needs a browser with Web Bluetooth; the S1 page needs Web Serial or Web Bluetooth. Chrome or Edge have both (on Linux, Chrome shows Web Bluetooth only with `--enable-experimental-web-platform-features`).

## Mac apps

The Mac apps use only Apple's system frameworks (AppKit, SwiftUI, Foundation, CoreBluetooth, PDFKit, CoreGraphics, CoreText, ImageIO, UniformTypeIdentifiers), with no third-party packages. They are built with `swiftc` from Apple's Command Line Tools, for macOS 13 or later.

## Keeping this up to date

- Python: `pip list --outdated` inside the virtual environment, and the advisories on each package's page.
- pdf.js: the [releases](https://github.com/mozilla/pdf.js/releases) and [OSV](https://osv.dev/list?q=pdfjs-dist). To update, download `pdfjs-dist` from npm, check its integrity value, replace the files in both `web/vendor/pdfjs/` folders, and update the version and hashes above.
