"""stlprofile: mesh stats, exact cross-sections and renders from STL files."""
import base64
import io
import json
import math
import struct
import subprocess
import sys
from pathlib import Path

import pytest
from PIL import Image

from cad_worker import stlprofile as sp


# --- fixtures: a 10 mm cube (0..10, 12 triangles) -----------------------------

CORNERS = [(x, y, z) for z in (0.0, 10.0) for y in (0.0, 10.0) for x in (0.0, 10.0)]


def _cube_facets():
    """(normal, v0, v1, v2) triples, outward winding."""
    idx = {p: i for i, p in enumerate(CORNERS)}
    quads = [
        # (normal, corners in outward CCW order, normal = (v1-v0) x (v2-v0))
        ((0, 0, -1), [(0, 0, 0), (0, 10, 0), (10, 10, 0), (10, 0, 0)]),
        ((0, 0, 1), [(0, 0, 10), (10, 0, 10), (10, 10, 10), (0, 10, 10)]),
        ((0, -1, 0), [(0, 0, 0), (10, 0, 0), (10, 0, 10), (0, 0, 10)]),
        ((0, 1, 0), [(0, 10, 0), (0, 10, 10), (10, 10, 10), (10, 10, 0)]),
        ((-1, 0, 0), [(0, 0, 0), (0, 0, 10), (0, 10, 10), (0, 10, 0)]),
        ((1, 0, 0), [(10, 0, 0), (10, 10, 0), (10, 10, 10), (10, 0, 10)]),
    ]
    facets = []
    for normal, quad in quads:
        facets.append((normal, quad[0], quad[1], quad[2]))
        facets.append((normal, quad[0], quad[2], quad[3]))
    return [(normal, CORNERS.index(a), CORNERS.index(b), CORNERS.index(c))
            for normal, a, b, c in facets]


def _binary_cube(path: Path):
    with open(path, "wb") as f:
        f.write(b"test cube".ljust(80, b"\0"))
        facets = _cube_facets()
        f.write(struct.pack("<I", len(facets)))
        for normal, a, b, c in facets:
            f.write(struct.pack("<12fH", *normal, *CORNERS[a], *CORNERS[b], *CORNERS[c], 0))


def _ascii_cube(path: Path):
    lines = ["solid cube"]
    for normal, a, b, c in _cube_facets():
        lines.append(f"  facet normal {normal[0]} {normal[1]} {normal[2]}")
        lines.append("    outer loop")
        for i in (a, b, c):
            x, y, z = CORNERS[i]
            lines.append(f"      vertex {x} {y} {z}")
        lines.append("    endloop")
        lines.append("  endfacet")
    lines.append("endsolid cube")
    path.write_text("\n".join(lines) + "\n")


def _sections_by_axis(result, axis):
    return [s for s in result["sections"] if s["axis"] == axis]


# --- stats + sections on the binary cube --------------------------------------

def test_binary_cube_stats(tmp_path):
    stl = tmp_path / "cube.stl"
    _binary_cube(stl)
    result = sp.analyze(str(stl))
    assert result["ok"] is True
    stats = result["stats"]
    assert stats["triangles"] == 12
    assert stats["vertices"] == 8
    assert stats["watertight"] is True
    assert stats["components"] == 1
    assert stats["volume"] == pytest.approx(1000.0, abs=0.01)
    assert stats["area"] == pytest.approx(600.0, abs=0.01)
    assert stats["bbox_min"] == [0.0, 0.0, 0.0]
    assert stats["bbox_size"] == [10.0, 10.0, 10.0]


def test_binary_cube_sections(tmp_path):
    stl = tmp_path / "cube.stl"
    _binary_cube(stl)
    result = sp.analyze(str(stl))
    assert len(result["sections"]) == 8

    # mid-X plane at 5.0: plane-local (y, z) quad corners
    xsec = [s for s in result["sections"] if s["axis"] == "x"]
    assert len(xsec) == 1 and xsec[0]["offset"] == 5.0
    assert len(xsec[0]["loops"]) == 1
    corners = {tuple(p) for p in xsec[0]["loops"][0]}
    assert corners == {(0.0, 0.0), (10.0, 0.0), (10.0, 10.0), (0.0, 10.0)}

    # every z section crosses the full 0..10 square
    for s in _sections_by_axis(result, "z"):
        assert len(s["loops"]) == 1
        pts = {tuple(p) for p in s["loops"][0]}
        assert pts == {(0.0, 0.0), (10.0, 0.0), (10.0, 10.0), (0.0, 10.0)}


def test_ascii_cube_same_stats(tmp_path):
    binary, ascii_stl = tmp_path / "b.stl", tmp_path / "a.stl"
    _binary_cube(binary)
    _ascii_cube(ascii_stl)
    b, a = sp.analyze(str(binary)), sp.analyze(str(ascii_stl))
    assert a["ok"] is True
    for key in ("triangles", "vertices", "watertight", "components", "volume", "area"):
        assert a["stats"][key] == b["stats"][key]


# --- renders -------------------------------------------------------------------

def test_renders_are_512_pngs(tmp_path):
    stl = tmp_path / "cube.stl"
    _binary_cube(stl)
    result = sp.analyze(str(stl))
    assert len(result["renders"]) == 4
    for b64 in result["renders"]:
        img = Image.open(io.BytesIO(base64.b64decode(b64)))
        assert img.size == (sp.RENDER_PX, sp.RENDER_PX)


# --- CLI -----------------------------------------------------------------------

def test_cli_ok_line(tmp_path):
    stl = tmp_path / "cube.stl"
    _binary_cube(stl)
    proc = subprocess.run(
        [sys.executable, "-m", "cad_worker.stlprofile", str(stl)],
        capture_output=True, text=True, cwd=Path(__file__).resolve().parent.parent,
    )
    assert proc.returncode == 0
    payload = json.loads(proc.stdout)
    assert payload["ok"] is True and payload["stats"]["triangles"] == 12


def test_cli_truncated_binary_exit1(tmp_path):
    stl = tmp_path / "broken.stl"
    _binary_cube(stl)
    data = stl.read_bytes()
    stl.write_bytes(data[: len(data) - 200])  # fewer than 12*50 bytes of facets
    proc = subprocess.run(
        [sys.executable, "-m", "cad_worker.stlprofile", str(stl)],
        capture_output=True, text=True, cwd=Path(__file__).resolve().parent.parent,
    )
    assert proc.returncode == 1
    payload = json.loads(proc.stdout)
    assert payload["ok"] is False
    assert "corrupt binary STL" in payload["error"]
