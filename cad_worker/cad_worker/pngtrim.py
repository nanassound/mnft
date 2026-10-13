"""Trim whitespace margins from a rendered datasheet page PNG.

pdftoppm renders full A4 pages; the technical drawing is usually a small
region of the page, so the vision model sees mostly margin. Cropping to the
content bbox multiplies the effective pixels per drawing edge.

CLI (one shot, no stdin):

    python -m cad_worker.pngtrim IN.png OUT.png

Behavior: pixels brighter than 245 are background; everything else is
content. Edge rows/columns that are uniformly blank or uniformly dark
(solid header/footer bands, page frames) are treated as chrome and
skipped, so the bbox covers the actual drawing. The content bbox is
cropped with 24 px padding per side, clamped to the page. A blank page
or a crop that keeps > 90% of the page passes the original through
unchanged. Every result — cropped or passed through — longer than
3000 px on its longest side is proportionally resized to 3000 px
(LANCZOS) to stay under the per-image byte caps and provider pixel
limits (e.g. Anthropic's 8000 px). Exit 0 on success; any failure
writes a message to stderr and exits 3. The input file is never
modified or deleted.
"""
from __future__ import annotations

import sys
from pathlib import Path

from PIL import Image

PADDING_PX = 24
WHITE_THRESHOLD = 245
MAX_LONGEST_SIDE = 3000
MAX_KEEP_RATIO = 0.9
# Row/column mean-darkness bounds: below ~1/255 is a blank margin, above 50%
# is a solid-dark run (bands; their white text rows stay ~80% dark). Drawing
# rule lines also cross 50%, so runs must also exceed the min_band thickness
# in edge_end to count as chrome.
BLANK_MEAN = 1.0 / 255.0
SOLID_MEAN = 0.5


def _content_bbox(gray: Image.Image) -> tuple[int, int, int, int] | None:
    """Bbox of content pixels, or None when the page is blank.

    Background is near-white (>245). Decorative chrome is skipped too: pages
    carry solid header/footer bands at the edge, and plain bbox-finding pins
    the crop to the full page because of them. Scan inward from each edge:
    blank margins are chrome, and solid-dark runs are chrome once thicker
    than `min_band` (page furniture — bands are hundreds of rows, drawing
    rule lines a few px, so thickness separates them; band text rows are
    still ~80% dark, so they count into the run). The first mixed row — or a
    too-thin solid run — is content and stops the scan. Rows run once over
    the full page, then columns once over the row-shrunk region. If a side
    has no content at all (blank page, all-solid page), fall back to the
    plain pixel bbox (the >90% passthrough rule handles it).
    """
    # 0 = background (near-white), 255 = content.
    mask = gray.point(lambda p: 0 if p > WHITE_THRESHOLD else 255)

    def edge_end(means: list[float], min_band: int) -> int | None:
        """Length of the leading chrome run, or None when nothing but
        chrome exists on this side (degenerate -> caller falls back)."""
        last_chrome = 0
        run = 0
        for i, m in enumerate(means):
            if m > SOLID_MEAN * 255:
                run += 1
                if run >= min_band:
                    last_chrome = i + 1
            elif m < BLANK_MEAN * 255:
                if 0 < run < min_band:
                    break  # thin solid line: content, not chrome
                run = 0
                last_chrome = i + 1
            else:
                break  # mixed: content
        return last_chrome

    rows = mask.resize((1, mask.height), Image.BOX).getdata()
    top = edge_end(list(rows), max(8, mask.height // 200))
    if top is None:
        return mask.getbbox()
    bottom = mask.height - edge_end(list(reversed(rows)), max(8, mask.height // 200))
    if bottom <= top:
        return mask.getbbox()

    cols = (
        mask.crop((0, top, mask.width, bottom))
        .resize((mask.width, 1), Image.BOX)
        .getdata()
    )
    left = edge_end(list(cols), max(8, mask.width // 200))
    if left is None:
        return mask.getbbox()
    right = mask.width - edge_end(list(reversed(cols)), max(8, mask.width // 200))
    if right <= left:
        return mask.getbbox()

    return (left, top, right, bottom)


def trim(src: Path, dst: Path) -> None:
    with Image.open(src) as im:
        bbox = _content_bbox(im.convert("L"))
        if bbox is None:
            # Blank page: nothing to crop, but the size cap still applies.
            out = im
        else:
            w, h = im.size
            left, top, right, bottom = bbox
            left = max(0, left - PADDING_PX)
            top = max(0, top - PADDING_PX)
            right = min(w, right + PADDING_PX)
            bottom = min(h, bottom + PADDING_PX)

            crop_w, crop_h = right - left, bottom - top
            if crop_w * crop_h > MAX_KEEP_RATIO * w * h:
                # Content covers (nearly) the whole page: nothing to gain,
                # but the size cap still applies (a full-bleed A1 sheet at
                # 300 dpi is ~9900x7000 px — over the 8000 px hard limit
                # some providers reject).
                out = im
            else:
                out = im.crop((left, top, right, bottom))

        longest = max(out.size)
        if longest > MAX_LONGEST_SIDE:
            scale = MAX_LONGEST_SIDE / longest
            out = out.resize(
                (round(out.width * scale), round(out.height * scale)),
                Image.LANCZOS,
            )
        out.save(dst, format="PNG", optimize=True)


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        sys.stderr.write("usage: python -m cad_worker.pngtrim IN.png OUT.png\n")
        return 3
    try:
        trim(Path(argv[0]), Path(argv[1]))
        return 0
    except Exception as exc:  # the Elixir caller falls back to the raw page
        sys.stderr.write(f"pngtrim failed: {type(exc).__name__}: {exc}\n")
        return 3


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
