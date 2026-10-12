"""Extract 2D section outlines from a datasheet PDF as vector coordinates.

Vision models trace datasheet drawings unreliably; the PDF itself contains the
drawing ink as vectors, so the outline can be read deterministically. This
module pulls the page's stroked paths, keeps the dominant "object ink" (the
thickest solid stroke style — Tiptop-style sheets draw part outlines with it
and dimension/centerline ink in thinner or dashed strokes), chains the strokes
into closed loops, flattens curves, and emits JSON:

    {"loops": [{"page": 1, "closed": true, "points": [[x, y], ...],
                "bbox": [w, h], "callouts": ["23.8", ...]}]}

Coordinates are PDF points (y up, origin moved to each loop's min corner).
Sheets draw views at per-view scales, so points are NOT millimetres: the
caller pairs the loops with the view's dimension callouts and applies one
uniform scale.

CLI: python -m cad_worker.pdfprofile IN.pdf [max_pages]  -> one JSON line.
Exit 0 with {"loops": []} when nothing closes; any failure exits 3 with a
message on stderr. The input file is never modified.
"""
from __future__ import annotations

import json
import math
import re
import sys

import pymupdf

SNAP = 2.0            # endpoint snapping grid, pt — split paths in real
                      # sheets leave up to ~2 pt gaps between shared corners
CURVE_SEGS = 12       # flatten resolution per cubic bezier
RDP_EPS = 0.25        # simplification tolerance, pt
MAX_LOOPS = 3         # closed loops reported per call
MAX_POINTS = 200      # per loop after simplification
CALLOUT_RE = re.compile(r"^\d+(?:[.,]\d+)?$|^M\d+$")


def _flatten(items: list) -> list[tuple[float, float]]:
    """One polyline (page coords, y down) from a drawing path's items."""
    pts: list[tuple[float, float]] = []
    for it in items:
        if it[0] == "l":
            seg = [(it[1].x, it[1].y), (it[2].x, it[2].y)]
        elif it[0] == "c":
            p0, p1, p2, p3 = it[1], it[2], it[3], it[4]
            seg = []
            for i in range(1, CURVE_SEGS + 1):
                t = i / CURVE_SEGS
                u = 1 - t
                x = u**3 * p0.x + 3 * u * u * t * p1.x + 3 * u * t * t * p2.x + t**3 * p3.x
                y = u**3 * p0.y + 3 * u * u * t * p1.y + 3 * u * t * t * p2.y + t**3 * p3.y
                seg.append((x, y))
        elif it[0] == "re":
            r = it[1]
            seg = [(r.x0, r.y0), (r.x1, r.y0), (r.x1, r.y1), (r.x0, r.y1), (r.x0, r.y0)]
        elif it[0] == "qu":
            q = it[1]
            seg = [
                (q.ul.x, q.ul.y),
                (q.ur.x, q.ur.y),
                (q.lr.x, q.lr.y),
                (q.ll.x, q.ll.y),
                (q.ul.x, q.ul.y),
            ]
        else:  # anything else: skip
            continue
        if pts and abs(pts[-1][0] - seg[0][0]) < 1e-6 and abs(pts[-1][1] - seg[0][1]) < 1e-6:
            pts.extend(seg[1:])
        else:
            pts.extend(seg)
    return pts


def _rdp(points: list[tuple[float, float]], eps: float) -> list[tuple[float, float]]:
    """Ramer-Douglas-Peucker; keeps the loop's first/last point (same point)."""
    if len(points) < 3:
        return points

    def perp(p, a, b):
        ax, ay = a; bx, by = b; px, py = p
        dx, dy = bx - ax, by - ay
        norm = math.hypot(dx, dy)
        if norm == 0:
            return math.hypot(px - ax, py - ay)
        return abs(dy * px - dx * py + bx * ay - by * ax) / norm

    keep = [False] * len(points)
    keep[0] = keep[-1] = True
    stack = [(0, len(points) - 1)]
    while stack:
        lo, hi = stack.pop()
        if hi <= lo + 1:
            continue
        dmax, imax = 0.0, -1
        for i in range(lo + 1, hi):
            d = perp(points[i], points[lo], points[hi])
            if d > dmax:
                dmax, imax = d, i
        if dmax > eps:
            keep[imax] = True
            stack.append((lo, imax))
            stack.append((imax, hi))
    return [p for p, k in zip(points, keep) if k]


def _chain_loops(segs: list[tuple[tuple[float, float], tuple[float, float]]]) -> list[list]:
    """Chain undirected segments into closed loops via endpoint matching.

    At junctions (touching tangent points, e.g. a keyhole circle) a greedy
    walk can dead-end, so candidates are tried with backtracking; the longest
    closed cycle from each start wins.
    """
    def key(p):
        return (round(p[0] / SNAP), round(p[1] / SNAP))

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

    # Walk over the shrinking live set: consumed segments must leave the graph,
    # or the next start re-traverses them. A start whose component has no
    # closed cycle (open chain) drops just that segment so the walk always
    # makes progress; its neighbours still get their own attempts.
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


def _solid(dashes) -> bool:
    """True when the stroke is not dashed ('', '[] 0', '[ 3 3 ] 0' variants)."""
    d = (dashes or "").replace(" ", "")
    return d in ("", "[]0", "[]")


def _loop_area(pts):
    a = 0.0
    for i in range(len(pts) - 1):
        x0, y0 = pts[i]; x1, y1 = pts[i + 1]
        a += x0 * y1 - x1 * y0
    return abs(a) / 2


def extract(pdf_path: str, max_pages: int = 3) -> dict:
    doc = pymupdf.open(pdf_path)
    loops = []
    for page_no in range(min(len(doc), max_pages)):
        page = doc[page_no]

        # Dominant solid stroke style = object ink on Tiptop-style sheets:
        # part outlines use the widest stroke; thinner styles are dimension,
        # hatch and centerline ink, dashed styles are hidden/centerline.
        styles: dict = {}
        for p in page.get_drawings():
            col = p.get("color")
            if col is None or p.get("fill") is not None:
                continue
            dashes = (p.get("dashes") or "").strip()
            if not _solid(dashes):
                continue
            k = (tuple(round(c, 2) for c in col), round(p.get("width") or 0, 2))
            styles[k] = styles.get(k, 0) + 1
        if not styles:
            continue
        ink = max(styles, key=lambda k: (k[1], styles[k]))

        segs = []
        for p in page.get_drawings():
            col = p.get("color")
            if col is None or p.get("fill") is not None:
                continue
            k = (tuple(round(c, 2) for c in col), round(p.get("width") or 0, 2))
            if k != ink or p.get("fill") is not None:
                continue
            if not _solid(p.get("dashes")):
                continue
            poly = _flatten(p["items"])
            for i in range(len(poly) - 1):
                segs.append((poly[i], poly[i + 1]))

        words = [
            (w[4], pymupdf.Rect(w[:4]))
            for w in page.get_text("words")
            if CALLOUT_RE.match(w[4])
        ]

        for loop in _chain_loops(segs):
            if len(loop) < 5:  # a closed quad is the smallest real outline
                continue
            simple = _rdp(loop, RDP_EPS)
            if len(simple) > MAX_POINTS:
                simple = _rdp(loop, RDP_EPS * 4)
            x0 = min(p[0] for p in simple); y0 = min(p[1] for p in simple)
            x1 = max(p[0] for p in simple); y1 = max(p[1] for p in simple)
            pts = [[round(px - x0, 2), round(y1 - py, 2)] for px, py in simple]
            # dimension labels sit above/below the extension lines, up to ~80pt
            # away from the outline on sheet-scale drawings
            rect = pymupdf.Rect(x0, y0, x1, y1) + (-80, -80, 80, 80)
            callouts = []
            for text, wr in words:
                if rect.intersects(wr) and text not in callouts:
                    callouts.append(text)
            loops.append({
                "page": page_no + 1,
                "closed": True,
                "points": pts,
                "bbox": [round(x1 - x0, 2), round(y1 - y0, 2)],
                "callouts": callouts[:16],
            })
        if len(loops) >= MAX_LOOPS:
            break
    return {"loops": loops[:MAX_LOOPS]}


def main(argv: list[str]) -> int:
    if not 1 <= len(argv) <= 2:
        sys.stderr.write("usage: python -m cad_worker.pdfprofile IN.pdf [max_pages]\n")
        return 3
    try:
        result = extract(argv[0], int(argv[1]) if len(argv) == 2 else 3)
        sys.stdout.write(json.dumps(result) + "\n")
        return 0
    except Exception as exc:
        sys.stderr.write(f"pdfprofile failed: {type(exc).__name__}: {exc}\n")
        return 3


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
