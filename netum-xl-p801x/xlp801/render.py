"""Turn PDFs, images and text into packed 1-bit pages for the print head."""

from __future__ import annotations

from pathlib import Path

from PIL import Image, ImageChops, ImageDraw, ImageEnhance, ImageFilter, ImageFont, ImageOps

from .protocol import DPMM, HEAD_DOTS, Paper

IMAGE_SUFFIXES = {".png", ".jpg", ".jpeg", ".gif", ".bmp", ".tif", ".tiff", ".webp", ".heic"}
TEXT_SUFFIXES = {".txt", ".md", ".csv", ".log"}


def load(path: Path, paper: Paper, pages: set[int] | None = None, margin_mm: float = 0) -> list[Image.Image]:
    """Return grayscale images exactly ``paper.width`` dots wide (height follows the source)."""
    suffix = path.suffix.lower()
    if suffix == ".pdf":
        return _load_pdf(path, paper, pages, margin_mm)
    if suffix in TEXT_SUFFIXES:
        return _render_text(path.read_text(errors="replace"), paper, margin_mm)
    if suffix in IMAGE_SUFFIXES:
        return [_fit(ImageOps.exif_transpose(Image.open(path)), paper, margin_mm)]
    raise ValueError(f"Unsupported file type: {path.suffix}")


def _content_width(paper: Paper, margin_mm: float) -> int:
    return paper.width - 2 * round(margin_mm * DPMM)


def _fit(img: Image.Image, paper: Paper, margin_mm: float) -> Image.Image:
    if img.mode in ("RGBA", "LA", "P"):
        img = img.convert("RGBA")
        bg = Image.new("RGBA", img.size, "white")
        img = Image.alpha_composite(bg, img)
    img = img.convert("L")
    if img.width > img.height * 1.2:  # landscape pictures print rotated, larger
        img = img.rotate(90, expand=True)
    w = _content_width(paper, margin_mm)
    img = img.resize((w, round(img.height * w / img.width)), Image.LANCZOS)
    return _pad(img, margin_mm)


def _pad(img: Image.Image, margin_mm: float) -> Image.Image:
    m = round(margin_mm * DPMM)
    if m == 0:
        return img
    out = Image.new("L", (img.width + 2 * m, img.height), 255)
    out.paste(img, (m, 0))
    return out


def _load_pdf(path: Path, paper: Paper, pages: set[int] | None, margin_mm: float) -> list[Image.Image]:
    import pymupdf

    out = []
    w = _content_width(paper, margin_mm)
    with pymupdf.open(path) as doc:
        for i, page in enumerate(doc, start=1):
            if pages and i not in pages:
                continue
            rect = page.rect
            if rect.width > rect.height:
                page.set_rotation((page.rotation + 90) % 360)
                rect = page.rect
            zoom = w / rect.width
            pix = page.get_pixmap(matrix=pymupdf.Matrix(zoom, zoom), colorspace=pymupdf.csGRAY, alpha=False)
            img = Image.frombytes("L", (pix.width, pix.height), pix.samples)
            out.append(_pad(img, margin_mm))
    return out


def _render_text(text: str, paper: Paper, margin_mm: float, size_pt: float = 11) -> list[Image.Image]:
    w = _content_width(paper, margin_mm)
    px = round(size_pt / 72 * 203)
    font = _font(px)
    probe = ImageDraw.Draw(Image.new("L", (1, 1)))
    lines: list[str] = []
    for para in text.expandtabs(4).splitlines() or [""]:
        line = ""
        for word in para.split(" "):
            cand = f"{line} {word}" if line else word
            if probe.textlength(cand, font=font) <= w:
                line = cand
                continue
            if line:
                lines.append(line)
            while probe.textlength(word, font=font) > w:  # hard-wrap long tokens
                cut = len(word)
                while cut > 1 and probe.textlength(word[:cut], font=font) > w:
                    cut -= 1
                lines.append(word[:cut])
                word = word[cut:]
            line = word
        lines.append(line)
    lh = round(px * 1.35)
    page_h = (paper.height - 2 * round(margin_mm * DPMM)) if paper.height else None
    per_page = max(page_h // lh, 1) if page_h else len(lines)  # a roll is one long page
    pages = []
    for start in range(0, len(lines), per_page):
        chunk = lines[start : start + per_page]
        img = Image.new("L", (w, page_h or len(chunk) * lh + lh // 2), 255)
        d = ImageDraw.Draw(img)
        for n, ln in enumerate(chunk):
            d.text((0, n * lh), ln, font=font, fill=0)
        pages.append(_pad(img, margin_mm))
    return pages


def _font(px: int) -> ImageFont.FreeTypeFont:
    for name in ("/System/Library/Fonts/Menlo.ttc", "/System/Library/Fonts/Supplemental/Arial.ttf",
                 "DejaVuSansMono.ttf"):
        try:
            return ImageFont.truetype(name, px)
        except OSError:
            continue
    return ImageFont.load_default(px)


def to_head(page: Image.Image, dither: str = "auto", brightness: float = 1.0,
            contrast: float = 1.0, offset: int = 24) -> tuple[bytes, Image.Image]:
    """Place a page on the 1728-dot head and pack it. Returns (bytes, 1-bit preview)."""
    if brightness != 1.0:
        page = ImageEnhance.Brightness(page).enhance(brightness)
    if contrast != 1.0:
        page = ImageEnhance.Contrast(page).enhance(contrast)
    canvas = Image.new("L", (HEAD_DOTS, page.height), 255)
    canvas.paste(page.crop((0, 0, min(page.width, HEAD_DOTS - offset), page.height)), (offset, 0))
    if dither == "auto":
        bw = _auto(canvas)
    elif dither == "threshold":
        bw = canvas.point(lambda v: 255 if v >= 128 else 0).convert("1", dither=Image.Dither.NONE)
    elif dither == "atkinson":
        bw = _atkinson(canvas)
    else:
        bw = canvas.convert("1", dither=Image.Dither.FLOYDSTEINBERG)
    packed = bytes(b ^ 0xFF for b in bw.tobytes())  # PIL "1": 1 = white; head: 1 = black
    return packed, bw


EDGE_RANGE = 96  # 3x3 grey range above which a dot belongs to an edge
EDGE_CUT = 150  # threshold on edges; above 128 so thin strokes print slightly bolder


def _auto(img: Image.Image) -> Image.Image:
    """Hard threshold on edges (text, lines), Floyd-Steinberg on flat grey areas.

    Dithering antialiased glyph edges makes text look fuzzy on a 203 dpi head.
    """
    edges = ImageChops.subtract(img.filter(ImageFilter.MaxFilter(3)), img.filter(ImageFilter.MinFilter(3)))
    mask = edges.point(lambda v: 255 if v > EDGE_RANGE else 0)
    flat = img.point(lambda v: 0 if v < 60 else 255 if v > 200 else round((v - 60) * 255 / 140))
    dithered = flat.convert("1", dither=Image.Dither.FLOYDSTEINBERG).convert("L")
    sharp = img.point(lambda v: 255 if v >= EDGE_CUT else 0)
    return Image.composite(sharp, dithered, mask).convert("1", dither=Image.Dither.NONE)


def _atkinson(img: Image.Image) -> Image.Image:
    w, h = img.size
    px = [float(v) for v in img.tobytes()]
    for y in range(h):
        row = y * w
        for x in range(w):
            i = row + x
            old = px[i]
            new = 255.0 if old >= 128 else 0.0
            px[i] = new
            err = (old - new) / 8
            if err == 0:
                continue
            for dx, dy in ((1, 0), (2, 0), (-1, 1), (0, 1), (1, 1), (0, 2)):
                nx, ny = x + dx, y + dy
                if 0 <= nx < w and ny < h:
                    px[ny * w + nx] += err
    out = Image.frombytes("L", (w, h), bytes(255 if v >= 128 else 0 for v in px))
    return out.convert("1", dither=Image.Dither.NONE)
