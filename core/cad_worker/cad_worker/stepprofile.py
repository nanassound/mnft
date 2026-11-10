"""Profile a STEP B-rep model for reverse engineering into parametric CAD code.

One-shot CLI like stlprofile: one JSON line on stdout.
  exit 0 -> {"ok": true, "stats": {...}, "sections": [...], "renders": [...]}
  exit 1 -> {"ok": false, "error": "human reason"}

Stats are exact B-rep figures (bounding box, volume, area, solids) plus a
face-type histogram — the exact version of the client's STEP entity regex.
Cross-sections and renders reuse stlprofile's mesh machinery: the shape is
tessellated once and fed to stlprofile._sections/_renders. Stats keys are a
superset of stlprofile's, so Mnft.Cad.Stl.format_block/2 works unchanged.
"""
from __future__ import annotations

import json
import os
import sys
from contextlib import contextmanager

import numpy as np
from build123d import import_step

from cad_worker.stlprofile import _renders, _sections

FACE_KEYS = ("plane", "cylinder", "cone", "torus", "sphere", "bspline")
# tessellation chord tolerance and angular tolerance, build123d units/radians
TESSELATE_TOL = 0.15
TESSELATE_ANG = 15


def _face_types(shape) -> dict:
    """Histogram of face surface types; zero entries omitted, exotic surfaces
    (bezier, revolution, offset, ...) lumped into the bspline bucket."""
    counts = dict.fromkeys(FACE_KEYS, 0)
    for f in shape.faces():
        name = f.geom_type.name.lower()
        counts[name if name in counts else "bspline"] += 1
    return {k: v for k, v in counts.items() if v}


def analyze(path: str) -> dict:
    shape = import_step(path)
    tris_v, tris_i = shape.tessellate(TESSELATE_TOL, TESSELATE_ANG)
    if not tris_v or not tris_i:
        raise ValueError("STEP contains no tessellatable geometry")
    verts = np.array([tuple(p) for p in tris_v], dtype=np.float64)
    mesh = verts[np.array(tris_i, dtype=np.int64)]  # (n, 3, 3)

    bb = shape.bounding_box()
    mn, mx = bb.min, bb.max
    solids = shape.solids()
    r4 = lambda v: round(float(v), 4)
    return {
        "ok": True,
        "stats": {
            "triangles": int(len(mesh)),
            "vertices": int(len(verts)),
            "bbox_min": [r4(mn.X), r4(mn.Y), r4(mn.Z)],
            "bbox_max": [r4(mx.X), r4(mx.Y), r4(mx.Z)],
            "bbox_size": [r4(mx.X - mn.X), r4(mx.Y - mn.Y), r4(mx.Z - mn.Z)],
            "volume": r4(shape.volume),
            "area": r4(shape.area),
            "watertight": len(solids) > 0,
            "components": len(solids),
            "face_types": _face_types(shape),
        },
        "sections": _sections(mesh),
        "renders": _renders(mesh),
    }


@contextmanager
def _quiet_stdout():
    """Silence OCCT's C-level stdout chatter (STEP parse banners) so the CLI
    keeps its one-JSON-line stdout contract; chatter goes to stderr instead.

    Belt: remove OCCT's default message printers at the source. Braces:
    redirect fd 1 to stderr — and flush all C streams INSIDE the window,
    because on Linux OCCT buffers the banner in std::cout and the buffer
    would otherwise flush onto the restored stdout after we leave."""
    _remove_occt_printers()
    sys.stdout.flush()
    saved = os.dup(1)
    os.dup2(2, 1)
    try:
        yield
        try:
            import ctypes

            ctypes.CDLL(None).fflush(None)
        except Exception:
            pass
    finally:
        os.dup2(saved, 1)
        os.close(saved)


def _remove_occt_printers():
    try:
        from OCP.Message import Message, Message_PrinterOStream

        Message.DefaultMessenger_s().RemovePrinters(
            Message_PrinterOStream.get_type_descriptor_s()
        )
    except Exception:
        pass


def main(argv: list[str]) -> int:
    if len(argv) != 1:
        sys.stderr.write("usage: python -m cad_worker.stepprofile IN.step\n")
        return 3
    try:
        with _quiet_stdout():
            result = analyze(argv[0])
    except Exception as exc:
        sys.stdout.write(json.dumps({"ok": False, "error": str(exc)}) + "\n")
        return 1
    sys.stdout.write(json.dumps(result) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
