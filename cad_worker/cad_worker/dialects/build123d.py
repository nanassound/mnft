"""build123d dialect: static checks and harness for build123d-based models."""
from __future__ import annotations

import ast
import re

ALLOWED_IMPORTS = frozenset({"build123d", "math"})

HARNESS = '''\
import json, math, os, struct, sys, traceback

out = {"ok": False, "error": None, "triangles": None, "bbox_mm": None,
       "volume_mm3": None, "glb": False}

def _finish(status=0):
    with open("_result.json", "w", encoding="utf-8") as fh:
        json.dump(out, fh)
    sys.exit(status)

# Math is on the static-check import allowlist, so pre-binding the module and
# its common bare names changes nothing about the security policy: it only
# means a script that forgot `import math` still runs. A script that imports
# math itself simply rebinds the same objects. Python builtins (pow, abs,
# round, min, max) are deliberately NOT shadowed.
ns = {
    "__name__": "__main__",
    "math": math,
    "pi": math.pi, "e": math.e, "tau": math.tau,
    "sin": math.sin, "cos": math.cos, "tan": math.tan,
    "asin": math.asin, "acos": math.acos, "atan": math.atan,
    "atan2": math.atan2, "sinh": math.sinh, "cosh": math.cosh,
    "tanh": math.tanh, "sqrt": math.sqrt, "radians": math.radians,
    "degrees": math.degrees, "hypot": math.hypot, "fabs": math.fabs,
    "floor": math.floor, "ceil": math.ceil, "trunc": math.trunc,
    "exp": math.exp, "log": math.log, "log10": math.log10,
    "copysign": math.copysign, "dist": math.dist, "isclose": math.isclose,
    "fmod": math.fmod, "modf": math.modf,
}
try:
    with open("_user_code.py", "r", encoding="utf-8") as fh:
        src = fh.read()
    exec(compile(src, "generated_code.py", "exec"), ns)
except BaseException:
    out["error"] = traceback.format_exc(limit=15)
    _finish(1)

from build123d import Compound, Shape, export_stl, export_step, export_gltf

def _pick(names):
    for name in names:
        val = ns.get(name)
        if isinstance(val, Shape):
            return val
        if hasattr(val, "part") and isinstance(getattr(val, "part"), Shape):
            return val.part  # tolerate builder-mode objects (BuildPart etc.)
        if isinstance(val, (list, tuple)):
            items = [s for s in val if isinstance(s, Shape)]
            if items:
                return Compound(children=items)
    return None

shape = _pick(("part", "result", "assembly", "obj"))
if shape is None:
    shape_like = sorted(
        k for k, v in ns.items() if not k.startswith("_") and isinstance(v, Shape)
    )
    out["error"] = (
        "no shape named 'part' (or result/assembly/obj) was defined; "
        "shape-like names found: " + (", ".join(shape_like) or "none")
    )
    _finish(1)

export_stl(shape, "model.stl", tolerance=0.15, angular_tolerance=0.25)
export_step(shape, "model.step")
try:
    # GLB is a phone-preview download, not the manufacturing file (STEP is).
    # Default deflection (0.001/0.1) tessellates ~3.4x the triangles of the STL
    # tolerance and its vertex array SIGSEGV'd the OCC writer under RLIMIT_AS
    # 3 GiB; 0.1/0.3 keeps the part visually identical at preview scale.
    export_gltf(shape, "model.glb", binary=True,
                linear_deflection=0.1, angular_deflection=0.3)
    with open("model.glb", "rb") as fh:
        out["glb"] = fh.read(4) == b"glTF"  # JSON glTF + unserved model.bin is useless
except Exception:
    out["glb"] = False  # glTF must never break an otherwise good run

with open("model.stl", "rb") as fh:
    fh.read(80)
    out["triangles"] = struct.unpack("<I", fh.read(4))[0]

bb = shape.bounding_box()
out["bbox_mm"] = [
    round(float(bb.size.X), 3),
    round(float(bb.size.Y), 3),
    round(float(bb.size.Z), 3),
]
out["volume_mm3"] = round(float(shape.volume), 3)
out["ok"] = True
_finish(0)
'''


def static_check(
    source: str,
    *,
    deny_funcs: frozenset,
    max_chars: int,
    dotted_fn,
) -> str | None:
    """Return a rejection reason, or None if the source may run."""
    if len(source) > max_chars:
        return f"generated code too large: {len(source)} chars (limit {max_chars})"
    if not re.search(r"\bpart\b", source):
        return "generated code never defines `part`"
    try:
        tree = ast.parse(source)
    except SyntaxError as exc:
        where = f" (line {exc.lineno})" if exc.lineno else ""
        return f"generated code has a syntax error{where}: {(exc.msg or 'invalid syntax').strip()}"
    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            for alias in node.names:
                root = alias.name.split(".")[0]
                if root not in ALLOWED_IMPORTS:
                    return f"import not allowed: {alias.name} (only build123d and math)"
        elif isinstance(node, ast.ImportFrom):
            if node.level or node.module is None:
                return "relative imports are not allowed (only build123d and math)"
            root = node.module.split(".")[0]
            if root not in ALLOWED_IMPORTS:
                return f"import not allowed: {node.module} (only build123d and math)"
        elif isinstance(node, ast.Call):
            func = node.func
            root, dotted = dotted_fn(func)
            if root in deny_funcs or (isinstance(func, ast.Attribute) and func.attr == "open"):
                return f"{dotted or '?'}() is not allowed (no file I/O, no eval/exec/__import__)"
        elif isinstance(node, ast.Name) and node.id == "random":
            return "random is not allowed (models must be deterministic)"
    return None


def health_info(python_ver: str) -> dict:
    import build123d
    return {"build123d": getattr(build123d, "__version__", "unknown"), "python": python_ver}
