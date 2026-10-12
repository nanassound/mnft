"""pdfprofile: vector section-outline extraction from datasheet PDFs.

Geometry helpers are tested on synthetic segments; extraction end-to-end on a
PDF generated in-test with known ink (thick solid outline + decoys).
"""
import json
import math
import subprocess
import sys
from pathlib import Path

import pymupdf

from cad_worker import pdfprofile as pp

REPO = Path(__file__).resolve().parent.parent


# --- _rdp ---------------------------------------------------------------------

def test_rdp_keeps_corners_drops_collinear():
    pts = [(0, 0), (1, 0), (2, 0), (2, 2)]  # (1,0) is collinear
    out = pp._rdp(pts, 0.1)
    assert out == [(0, 0), (2, 0), (2, 2)]


def test_rdp_keeps_loop_open_point_identity():
    ring = [(math.cos(2 * math.pi * i / 36), math.sin(2 * math.pi * i / 36)) for i in range(37)]
    out = pp._rdp(ring, 0.05)
    assert out[0] == ring[0] and out[-1] == ring[-1]
    assert 4 <= len(out) < len(ring)  # simplified but still a closed ring


# --- _chain_loops ---------------------------------------------------------------

def test_chain_square_closed():
    segs = [((0, 0), (10, 0)), ((10, 0), (10, 10)), ((10, 10), (0, 10)), ((0, 10), (0, 0))]
    loops = pp._chain_loops(segs)
    assert len(loops) == 1 and len(loops[0]) == 5  # 4 corners + closing repeat


def test_chain_dangling_tail_is_dropped_not_looped():
    square = [((0, 0), (10, 0)), ((10, 0), (10, 10)), ((10, 10), (0, 10)), ((0, 10), (0, 0))]
    tail = [((0, 0), (5, -5))]  # open spur off a corner
    loops = pp._chain_loops(square + tail)
    assert len(loops) == 1
    assert all(y >= 0 for _x, y in loops[0])  # tail never entered a loop


def test_chain_keyhole_junction_yields_cycle():
    # circle tangent to a square edge: two shared nodes -> degree-4 junctions
    segs = [((0, 0), (10, 0)), ((10, 0), (10, 10)), ((10, 10), (0, 10)), ((0, 10), (0, 0))]
    n = 16
    circ = [
        ((4 + 2 * math.cos(2 * math.pi * i / n), 5 + 2 * math.sin(2 * math.pi * i / n)),
         (4 + 2 * math.cos(2 * math.pi * (i + 1) / n), 5 + 2 * math.sin(2 * math.pi * (i + 1) / n)))
        for i in range(n)
    ]
    # weld the circle to the left edge at (0,5) by snapping one node there
    circ[0] = ((0, 5), circ[0][1])
    circ[-1] = (circ[-1][0], (0, 5))
    loops = pp._chain_loops(segs + circ)
    assert loops, "junction graph must still close a cycle"


# --- extract/CLI on a generated PDF ---------------------------------------------

def _inked_pdf(path: Path):
    doc = pymupdf.open()
    page = doc.new_page(width=400, height=300)
    green, red = (0.23, 0.39, 0.18), (0.75, 0.08, 0.12)
    shape = page.new_shape()
    # object ink: thick solid green closed profile with a rounded corner
    pts = [(50, 50), (150, 50), (150, 110), (50, 110)]
    for a, b in zip(pts, pts[1:] + pts[:1]):
        shape.draw_line(pymupdf.Point(*a), pymupdf.Point(*b))
    shape.finish(color=green, width=2.13)
    # decoy: dashed thick green (hidden ink) — must be ignored
    shape.draw_line(pymupdf.Point(200, 50), pymupdf.Point(300, 50))
    shape.finish(color=green, width=2.13, dashes="[3 3] 0")
    # decoy: thin red dimension line + label
    shape.draw_line(pymupdf.Point(50, 30), pymupdf.Point(150, 30))
    shape.finish(color=red, width=0.28)
    shape.insert_text((80, 25), "42.5", fontsize=9, color=red)
    # decoy: filled path (hatch fill) — must be ignored
    shape.draw_rect(pymupdf.Rect(200, 100, 260, 140))
    shape.finish(color=green, fill=(0.9, 0.9, 0.9))
    shape.commit()
    doc.save(path)


def test_extract_finds_outline_ignores_decoys(tmp_path):
    pdf = tmp_path / "sheet.pdf"
    _inked_pdf(pdf)
    res = pp.extract(str(pdf), 1)
    assert len(res["loops"]) == 1
    loop = res["loops"][0]
    assert loop["page"] == 1 and loop["closed"] is True
    assert 99 < loop["bbox"][0] < 101 and 59 < loop["bbox"][1] < 61  # 100x60pt outline
    xs = [p[0] for p in loop["points"]]
    ys = [p[1] for p in loop["points"]]
    assert min(xs) == 0 and min(ys) == 0  # origin at min corner, y up
    assert "42.5" in loop["callouts"]


def test_extract_no_ink_returns_empty(tmp_path):
    doc = pymupdf.open()
    doc.new_page(width=200, height=200)
    pdf = tmp_path / "blank.pdf"
    doc.save(pdf)
    assert pp.extract(str(pdf), 1) == {"loops": []}


def test_cli_missing_file_exit3(tmp_path):
    proc = subprocess.run(
        [sys.executable, "-m", "cad_worker.pdfprofile", str(tmp_path / "nope.pdf")],
        capture_output=True, text=True, cwd=REPO, timeout=30)
    assert proc.returncode == 3
    assert "pdfprofile failed" in proc.stderr
