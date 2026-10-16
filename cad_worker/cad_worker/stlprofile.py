"""Profile an STL mesh for reverse engineering into parametric CAD code.

One-shot CLI like pdfprofile: one JSON line on stdout.
  exit 0 -> {"ok": true, "stats": {...}, "sections": [...], "renders": [...]}
  exit 1 -> {"ok": false, "error": "human reason"}

Sections are exact mesh-plane intersections chained into closed loops (the
pdfprofile trick applied to meshes); renders are flat-shaded orthographic
views. Both feed the LLM prompt so it can rebuild the part parametrically.
"""
from __future__ import annotations

import base64
import io
import json
import math
import re
import struct
import sys
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw

Z_SECTIONS = 6        # z levels between bbox bottom and top
RENDER_PX = 512       # orthographic render size, px
LOOP_MAX = 3          # closed loops reported per section
PT_MAX = 200          # per loop after simplification
DP_TOL = 0.05         # Douglas-Peucker tolerance, STL units

_VERTEX_RE = re.compile(r"vertex\s+(\S+)\s+(\S+)\s+(\S+)", re.IGNORECASE)
AXIS_IDX = {"x": 0, "y": 1, "z": 2}
PLANE_UV = {"x": (1, 2), "y": (0, 2), "z": (0, 1)}  # plane-local 2D components

# View direction (into the scene) + world up per render: front, top, right, iso
_ISO_YAW, _ISO_PITCH = math.radians(30), math.radians(25)
_VIEWS = [
    (np.array([0.0, 1.0, 0.0]), np.array([0.0, 0.0, 1.0])),
    (np.array([0.0, 0.0, -1.0]), np.array([0.0, 1.0, 0.0])),
    (np.array([-1.0, 0.0, 0.0]), np.array([0.0, 0.0, 1.0])),
    (np.array([-math.cos(_ISO_PITCH) * math.cos(_ISO_YAW),
               -math.cos(_ISO_PITCH) * math.sin(_ISO_YAW),
               -math.sin(_ISO_PITCH)]), np.array([0.0, 0.0, 1.0])),
]


def _load(path: str) -> np.ndarray:
    """Triangles as (n, 3, 3) float64; raises ValueError with a human reason."""
    data = Path(path).read_bytes()
    head = data[:512].lstrip()
    if head[:5].lower() == b"solid" and b"facet" in head[:512]:
        return _load_ascii(data)
    return _load_binary(data)


def _load_binary(data: bytes) -> np.ndarray:
    if len(data) < 84:
        raise ValueError("binary STL too short to hold a triangle count")
    (n,) = struct.unpack_from("<I", data, 80)
    room = (len(data) - 84) // 50
    if n > room:
        raise ValueError(f"corrupt binary STL (declared {n} triangles, room for {room})")
    if n == 0:
        raise ValueError("STL contains no triangles")
    dt = np.dtype([("normal", "<f4", (3,)), ("v", "<f4", (3, 3)), ("attr", "<u2")])
    rec = np.frombuffer(data, dtype=dt, count=n, offset=84)
    return rec["v"].astype(np.float64)


def _load_ascii(data: bytes) -> np.ndarray:
    vals = _VERTEX_RE.findall(data.decode("latin-1"))
    if not vals:
        raise ValueError("ASCII STL contains no vertices")
    if len(vals) % 3:
        raise ValueError(f"ASCII STL vertex count {len(vals)} is not a multiple of 3")
    try:
        arr = np.array([[float(c) for c in trip] for trip in vals], dtype=np.float64)
    except ValueError:
        raise ValueError("ASCII STL has non-numeric vertex coordinates") from None
    return arr.reshape(-1, 3, 3)


def _stats(verts: np.ndarray) -> dict:
    flat = np.round(verts, 6).reshape(-1, 3)
    uniq, inv = np.unique(flat, axis=0, return_inverse=True)
    ids = inv.reshape(-1, 3)
    edges = np.sort(np.concatenate([ids[:, [0, 1]], ids[:, [1, 2]], ids[:, [2, 0]]]), axis=1)
    _, counts = np.unique(edges, axis=0, return_counts=True)
    watertight = bool(counts.size and (counts == 2).all())

    parent = list(range(len(uniq)))

    def find(x):
        while parent[x] != x:
            parent[x] = parent[parent[x]]
            x = parent[x]
        return x

    for a, b in edges.tolist():
        ra, rb = find(a), find(b)
        if ra != rb:
            parent[ra] = rb
    components = len({find(i) for i in range(len(uniq))})

    v0, v1, v2 = verts[:, 0], verts[:, 1], verts[:, 2]
    volume = float(np.einsum("ij,ij->i", v0, np.cross(v1, v2)).sum() / 6.0)
    area = float((np.linalg.norm(np.cross(v1 - v0, v2 - v0), axis=1) / 2).sum())
    mn = verts.reshape(-1, 3).min(axis=0)
    mx = verts.reshape(-1, 3).max(axis=0)
    r4 = lambda v: round(float(v), 4)
    return {
        "triangles": int(len(verts)),
        "vertices": int(len(uniq)),
        "bbox_min": [r4(v) for v in mn],
        "bbox_max": [r4(v) for v in mx],
        "bbox_size": [r4(v) for v in (mx - mn)],
        "volume": r4(abs(volume)),
        "area": r4(area),
        "watertight": watertight,
        "components": components,
    }


def key(p):
    """Endpoint key: quantized to 4 dp so shared corners stitch together."""
    return (round(p[0], 4), round(p[1], 4))


def _chain_loops(segs):
    """Chain undirected segments into closed loops via quantized endpoints.

    Same live-set DFS walker as pdfprofile._chain_loops; segments that never
    close a cycle are dropped one by one, so only closed loops come back
    (first point repeated at the end).
    """
    adj: dict = {}
    for i, (a, b) in enumerate(segs):
        adj.setdefault(key(a), []).append((i, a))
        adj.setdefault(key(b), []).append((i, b))

    loops: list = []
    unused = set(range(len(segs)))

    def walk(start_seg, start_dir, seg_by_id, adj, budget):
        """Longest closed loop beginning with start_seg (from start_dir end)."""
        a0, b0 = seg_by_id[start_seg]
        chain = [a0, b0] if start_dir == 0 else [b0, a0]
        used = {start_seg}
        best = None
        steps = [0]

        def dfs(last_pt):
            nonlocal best
            if best is not None or steps[0] > budget:
                return
            steps[0] += 1
            if len(chain) > 2 and key(last_pt) == key(chain[0]):
                best = list(chain)
                return
            for j, _p in adj.get(key(last_pt), []):
                if j in used:
                    continue
                x, y = seg_by_id[j]
                nxt = y if key(x) == key(last_pt) else x
                if key(nxt) == key(last_pt):
                    continue
                used.add(j)
                chain.append(nxt)
                dfs(nxt)
                if best is not None:
                    return
                chain.pop()
                used.discard(j)

        dfs(chain[-1])
        return (best, used) if best else (None, None)

    budget = 20000
    while unused:
        live = sorted(unused)
        seg_by_id = {new: segs[old] for new, old in enumerate(live)}
        adj: dict = {}
        for i, (a, b) in seg_by_id.items():
            adj.setdefault(key(a), []).append((i, a))
            adj.setdefault(key(b), []).append((i, b))

        loop, used = walk(0, 0, seg_by_id, adj, budget)
        if not loop:
            loop, used = walk(0, 1, seg_by_id, adj, budget)
        if loop:
            loops.append(loop)
            unused -= {live[j] for j in used}
        else:
            unused.discard(live[0])
    return loops


def _perp(p, a, b):
    """Distance of p from the line a-b; degenerate chord -> distance to a."""
    ax, ay = a
    bx, by = b
    px, py = p
    dx, dy = bx - ax, by - ay
    norm = math.hypot(dx, dy)
    if norm == 0:
        return math.hypot(px - ax, py - ay)
    return abs(dy * px - dx * py + bx * ay - by * ax) / norm


def _prune_collinear(ring, eps):
    """Drop vertices within eps of the line through their neighbours.

    RDP must anchor a closed ring at its first vertex even when that vertex
    is mid-edge; this cyclic pass removes it (and near-collinear jitter).
    """
    n = len(ring)
    dropped = [_perp(ring[i], ring[i - 1], ring[(i + 1) % n]) <= eps for i in range(n)]
    return [p for p, d in zip(ring, dropped) if not d]


def _rdp(points, eps):
    """Ramer-Douglas-Peucker; keeps the loop's first/last points (same point
    for closed chains: a degenerate chord falls back to point distance, which
    splits the ring at its farthest vertex)."""
    if len(points) < 3:
        return list(points)

    keep = [False] * len(points)
    keep[0] = keep[-1] = True
    stack = [(0, len(points) - 1)]
    while stack:
        lo, hi = stack.pop()
        if hi <= lo + 1:
            continue
        dmax, imax = 0.0, -1
        for i in range(lo + 1, hi):
            d = _perp(points[i], points[lo], points[hi])
            if d > dmax:
                dmax, imax = d, i
        if dmax > eps:
            keep[imax] = True
            stack.append((lo, imax))
            stack.append((imax, hi))
    return [p for p, k in zip(points, keep) if k]


def _section_segments(verts, axis_idx, h, ui, vi):
    """Quantized 2D segments where the plane at h cuts crossing triangles."""
    d = verts[:, :, axis_idx] - h
    side = d >= 0
    crossing = (side[:, 0] != side[:, 1]) | (side[:, 1] != side[:, 2])
    segs = []
    for t in np.nonzero(crossing)[0]:
        pts = verts[t]
        dt = d[t]
        hits = []
        for i in range(3):
            j = (i + 1) % 3
            if side[t, i] != side[t, j]:
                k = dt[i] / (dt[i] - dt[j])
                hits.append(pts[i] + (pts[j] - pts[i]) * k)
        if len(hits) == 2:
            a = (float(hits[0][ui]), float(hits[0][vi]))
            b = (float(hits[1][ui]), float(hits[1][vi]))
            if key(a) != key(b):
                segs.append((a, b))
    return segs


def _bbox_area(ring):
    xs = [p[0] for p in ring]
    ys = [p[1] for p in ring]
    return (max(xs) - min(xs)) * (max(ys) - min(ys))


def _one_section(verts, axis, h):
    ui, vi = PLANE_UV[axis]
    chains = []
    for chain in _chain_loops(_section_segments(verts, AXIS_IDX[axis], h, ui, vi)):
        chains.append(chain)  # closed: first point repeated at the end
    chains.sort(key=_bbox_area, reverse=True)
    loops = []
    for chain in chains[:LOOP_MAX]:
        simple = _rdp(chain, DP_TOL)
        if len(simple) > PT_MAX + 1:
            simple = _rdp(chain, DP_TOL * 4)
        ring = simple[:-1]  # drop the closing repeat
        if len(ring) >= 3:
            ring = _prune_collinear(ring, DP_TOL)
        if len(ring) < 3:
            continue
        if len(ring) > PT_MAX:  # emergency: thin the ring, keep it valid
            step = math.ceil(len(ring) / PT_MAX)
            ring = ring[::step]
        loops.append([[round(x, 3), round(y, 3)] for x, y in ring])
    return {"axis": axis, "offset": round(float(h), 4), "loops": loops}


def _sections(verts) -> list:
    mn = verts.reshape(-1, 3).min(axis=0)
    mx = verts.reshape(-1, 3).max(axis=0)
    out = []
    for i in range(Z_SECTIONS):
        out.append(_one_section(verts, "z", mn[2] + (i + 0.5) * (mx[2] - mn[2]) / Z_SECTIONS))
    out.append(_one_section(verts, "x", (mn[0] + mx[0]) / 2))
    out.append(_one_section(verts, "y", (mn[1] + mx[1]) / 2))
    return out


def _render_view(verts, f, up_world) -> str:
    """Base64 PNG: orthographic view, backface-culled painter's algorithm."""
    f = f / np.linalg.norm(f)
    r = np.cross(f, up_world)
    r = r / np.linalg.norm(r)
    u = np.cross(r, f)
    px = verts @ r
    py = verts @ u
    depth = (verts @ f).mean(axis=1)
    normals = np.cross(verts[:, 1] - verts[:, 0], verts[:, 2] - verts[:, 0])
    nl = np.linalg.norm(normals, axis=1)
    nl[nl == 0] = 1.0
    normals = normals / nl[:, None]
    visible = (normals @ f) < 0
    light = u * 0.7 - f * 0.5
    light = light / np.linalg.norm(light)
    shade = np.clip(normals @ light, 0.0, 1.0)

    x0, x1 = float(px.min()), float(px.max())
    y0, y1 = float(py.min()), float(py.max())
    span = max(x1 - x0, y1 - y0, 1e-9)
    scale = RENDER_PX * 0.9 / span
    ox = (RENDER_PX - (x1 - x0) * scale) / 2 - x0 * scale
    # screen y grows downward: flip so +u (world up) points up the image
    oy = (RENDER_PX - (y1 - y0) * scale) / 2 + y1 * scale
    X = px * scale + ox
    Y = oy - py * scale

    img = Image.new("RGB", (RENDER_PX, RENDER_PX), (255, 255, 255))
    draw = ImageDraw.Draw(img)
    for i in np.argsort(-depth):
        if not visible[i]:
            continue
        g = int(145 + 110 * shade[i])
        draw.polygon([(X[i, 0], Y[i, 0]), (X[i, 1], Y[i, 1]), (X[i, 2], Y[i, 2])],
                     fill=(g, g, g))
    buf = io.BytesIO()
    img.save(buf, "PNG")
    return base64.b64encode(buf.getvalue()).decode("ascii")


def _renders(verts) -> list:
    return [_render_view(verts, f, up) for f, up in _VIEWS]


def analyze(path: str) -> dict:
    verts = _load(path)
    return {
        "ok": True,
        "stats": _stats(verts),
        "sections": _sections(verts),
        "renders": _renders(verts),
    }


def main(argv: list[str]) -> int:
    if len(argv) != 1:
        sys.stderr.write("usage: python -m cad_worker.stlprofile IN.stl\n")
        return 3
    try:
        result = analyze(argv[0])
    except Exception as exc:
        sys.stdout.write(json.dumps({"ok": False, "error": str(exc)}) + "\n")
        return 1
    sys.stdout.write(json.dumps(result) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
