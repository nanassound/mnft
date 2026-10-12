"""pngtrim: content-bbox trimming of rendered datasheet pages.

Runs the module exactly as the Elixir side does (python -m cad_worker.pngtrim)
and pins the observable contract: padding, passthrough cases, resize cap,
and the exit-3 failure mode.
"""
import subprocess
import sys
from pathlib import Path

from PIL import Image, ImageDraw

REPO = Path(__file__).resolve().parent.parent


def _run(src: Path, dst: Path):
    return subprocess.run(
        [sys.executable, "-m", "cad_worker.pngtrim", str(src), str(dst)],
        capture_output=True, text=True, cwd=REPO, timeout=30)


def _write(path: Path, size, bg):
    im = Image.new("L", size, bg)
    im.save(path)
    return im


def test_trims_to_content_plus_padding(tmp_path):
    src, dst = tmp_path / "page.png", tmp_path / "trimmed.png"
    # 401x301 outlined rect on a 1000x1000 page -> crop = rect + 24 px pad/side
    # (the rect's 6px border runs are thinner than min_band, so they are kept).
    im = _write(src, (1000, 1000), 255)
    ImageDraw.Draw(im).rectangle([300, 350, 700, 650], outline=0, width=6)
    im.save(src)
    proc = _run(src, dst)
    assert proc.returncode == 0, proc.stderr
    assert Image.open(dst).size == (449, 349)
    assert src.exists()  # input is never deleted


def test_blank_page_passes_through_unchanged(tmp_path):
    src, dst = tmp_path / "page.png", tmp_path / "trimmed.png"
    _write(src, (1000, 1000), 255)
    proc = _run(src, dst)
    assert proc.returncode == 0, proc.stderr
    assert Image.open(dst).size == (1000, 1000)


def test_full_page_content_passes_through(tmp_path):
    # Crop would keep > 90% of the page: no win, pass the original through.
    src, dst = tmp_path / "page.png", tmp_path / "trimmed.png"
    _write(src, (1000, 1000), 0)
    proc = _run(src, dst)
    assert proc.returncode == 0, proc.stderr
    assert Image.open(dst).size == (1000, 1000)


def test_oversize_crop_resized_to_3000_longest_side(tmp_path):
    src, dst = tmp_path / "page.png", tmp_path / "trimmed.png"
    # Crop would be 3049x249 -> longest side scaled down to 3000.
    im = _write(src, (3600, 2000), 255)
    ImageDraw.Draw(im).rectangle([300, 900, 3300, 1100], outline=0, width=6)
    im.save(src)
    proc = _run(src, dst)
    assert proc.returncode == 0, proc.stderr
    assert Image.open(dst).size == (3000, 245)


def test_solid_bands_at_edges_do_not_pin_the_bbox(tmp_path):
    # Datasheet chrome: solid black header/footer bands. A plain pixel bbox
    # spans the full page; the trim must skip uniform-dark edge rows/cols and
    # crop to the drawing.
    src, dst = tmp_path / "page.png", tmp_path / "trimmed.png"
    im = _write(src, (1000, 1000), 255)
    d = ImageDraw.Draw(im)
    d.rectangle([0, 0, 999, 99], fill=0)
    d.rectangle([0, 900, 999, 999], fill=0)
    d.rectangle([350, 400, 650, 700], outline=0, width=6)
    im.save(src)
    proc = _run(src, dst)
    assert proc.returncode == 0, proc.stderr
    assert Image.open(dst).size == (349, 349)


def test_missing_input_fails_with_stderr_and_no_output(tmp_path):
    src, dst = tmp_path / "missing.png", tmp_path / "trimmed.png"
    proc = _run(src, dst)
    assert proc.returncode == 3
    assert proc.stdout == ""
    assert "pngtrim failed" in proc.stderr
    assert not dst.exists()
