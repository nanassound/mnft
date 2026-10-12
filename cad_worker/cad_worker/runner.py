"""Guarded execution of LLM-generated build123d code.

Layers, in order:
1. static pre-check (length, part binding, import allowlist, call denylist);
2. isolated subprocess (`python -I -B`) with a minimal environment;
3. rlimits (address space, CPU, file descriptors) + wall-clock kill of the
   whole process group;
4. per-model working dir; only model.stl/model.step/model.glb are ever served.

These are defence-in-depth against accidents and prompt slips — NOT a hardened
sandbox. See the repo README for the honest threat model.

Ported from the PoC's `backend/runner.py`; concurrency limiting and model-dir
retention moved up into the Elixir tier.
"""
from __future__ import annotations

import ast
import json
import os
import re
import resource
import signal
import subprocess
import sys
import time
from pathlib import Path

ALLOWED_IMPORTS = frozenset({"build123d", "math"})
ALLOWED_FILENAMES = frozenset({"model.stl", "model.step", "model.glb"})
MODEL_ID_RE = re.compile(r"^[0-9a-f]{8,32}$")
_DENY_FUNCS = frozenset({"open", "eval", "exec", "__import__"})

MAX_SOURCE_CHARS = int(os.environ.get("MAX_SOURCE_CHARS", "20000"))
EXEC_TIMEOUT_S = float(os.environ.get("EXEC_TIMEOUT_S", "60"))
CPU_LIMIT_S = 45
# 4 GiB, measured: binary glTF export of threaded-screw geometry deterministically
# SIGSEGVs at the 3 GiB limit (OCC glTF writer hits the address-space ceiling;
# uncatchable -> whole harness dies). glb succeeds in <1 s at 4 GiB; container
# mem_limit is 6 g and RLIMIT_AS caps virtual, not resident, memory.
AS_LIMIT_BYTES = 4 * 1024**3
NOFILE_LIMIT = 256

# Runs inside the per-model dir with cwd/TMPDIR/HOME pointed at it.
_HARNESS = '''\
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


def _dotted(node: ast.expr) -> tuple[str | None, str]:
    """(root identifier, dotted name) of a Name/Attribute chain; (None, '') for
    anything more exotic (subscripts, calls...)."""
    parts: list[str] = []
    while isinstance(node, ast.Attribute):
        parts.append(node.attr)
        node = node.value
    if isinstance(node, ast.Name):
        parts.append(node.id)
        parts.reverse()
        return parts[0], ".".join(parts)
    return None, ""


def static_check(source: str) -> str | None:
    """Return a rejection reason, or None if the source may run."""
    if len(source) > MAX_SOURCE_CHARS:
        return f"generated code too large: {len(source)} chars (limit {MAX_SOURCE_CHARS})"
    if not re.search(r"\bpart\b", source):
        return "generated code never defines `part`"
    try:
        tree = ast.parse(source)
    except SyntaxError as exc:
        # free information: hand the repair pass a precise complaint instead of
        # letting a runtime traceback be the first thing anyone sees
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
            root, dotted = _dotted(func)
            if root in _DENY_FUNCS or (isinstance(func, ast.Attribute) and func.attr == "open"):
                return f"{dotted or '?'}() is not allowed (no file I/O, no eval/exec/__import__)"
        elif isinstance(node, ast.Name) and node.id == "random":
            # exact identifier: `randomness` or `my_random_var` must not trip
            return "random is not allowed (models must be deterministic)"
    return None


def error_summary(error: str | None) -> str:
    """The headline for the UI: a traceback's last non-empty line is the
    exception message (e.g. ``RuntimeError: BuildPart doesn't have a Helix ...``).
    Falls back to the whole (single-line) message."""
    if not error or not error.strip():
        return "unknown error"
    lines = [ln.strip() for ln in error.strip().splitlines() if ln.strip()]
    return lines[-1][:300]


def valid_model_id(model_id: str) -> bool:
    return bool(MODEL_ID_RE.fullmatch(model_id))


def valid_filename(filename: str) -> bool:
    return filename in ALLOWED_FILENAMES


def execute(source: str, model_dir: Path) -> dict:
    """Run *source* through the harness inside *model_dir* (created here).

    Never raises; returns a result dict. Concurrency and retention are owned by
    the Elixir caller — this function is single-shot.
    """
    model_dir = Path(model_dir).resolve()
    model_dir.mkdir(parents=True, exist_ok=True)
    result: dict = {"ok": False, "error": None, "artifacts": None, "mesh": None,
                    "exec_ms": 0}
    raw: dict = {"ok": False, "error": "not run"}
    t0 = time.monotonic()  # harness runtime only — queueing happens upstream
    try:
        (model_dir / "_user_code.py").write_text(source, encoding="utf-8")
        (model_dir / "_harness.py").write_text(_HARNESS, encoding="utf-8")
        raw = _run_harness(model_dir)
    except Exception as exc:  # runner-level failure: report, never raise
        raw = {"ok": False, "error": f"runner failure: {type(exc).__name__}: {exc}"}
    finally:
        for name in ("_user_code.py", "_harness.py", "_result.json"):
            try:
                (model_dir / name).unlink()
            except OSError:
                pass
    result["exec_ms"] = int((time.monotonic() - t0) * 1000)

    if not raw.get("ok"):
        result["error"] = (raw.get("error") or "execution failed")[-2000:]
        return result

    stl = model_dir / "model.stl"
    step = model_dir / "model.step"
    glb = model_dir / "model.glb"
    if not (stl.is_file() and step.is_file()):
        result["error"] = "harness reported ok but exports are missing"
        return result
    result["ok"] = True
    result["artifacts"] = {
        "model_id": model_dir.name,
        "stl": "model.stl",
        "step": "model.step",
        "glb": "model.glb" if glb.is_file() else None,
    }
    result["mesh"] = {
        "triangles": raw.get("triangles"),
        "bbox_mm": raw.get("bbox_mm"),
        "volume_mm3": raw.get("volume_mm3"),
    }
    return result


def _run_harness(workdir: Path) -> dict:
    env = {
        "PATH": "/usr/local/bin:/usr/bin:/bin",
        "HOME": str(workdir),
        "TMPDIR": str(workdir),
        "LANG": "C.UTF-8",
        "LC_ALL": "C.UTF-8",
    }

    def _limits():  # runs in the forked child, before exec
        def _set(res, pair):
            # darwin rejects some setrlimit calls (e.g. RLIMIT_AS above its
            # ceiling -> EINVAL); on Linux the same call must stay strict.
            if sys.platform == "darwin":
                try:
                    resource.setrlimit(res, pair)
                except (OSError, ValueError):
                    pass
            else:
                resource.setrlimit(res, pair)

        _set(resource.RLIMIT_AS, (AS_LIMIT_BYTES, AS_LIMIT_BYTES))
        _set(resource.RLIMIT_CPU, (CPU_LIMIT_S, CPU_LIMIT_S))
        _set(resource.RLIMIT_NOFILE, (NOFILE_LIMIT, NOFILE_LIMIT))
        os.setsid()

    proc = subprocess.Popen(
        [sys.executable, "-I", "-B", "_harness.py"],
        cwd=str(workdir),
        env=env,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.PIPE,
        preexec_fn=_limits,
    )
    try:
        _, err = proc.communicate(timeout=int(EXEC_TIMEOUT_S))
    except subprocess.TimeoutExpired:
        try:  # kill the whole group so orphaned children die too
            os.killpg(proc.pid, signal.SIGKILL)
        except (ProcessLookupError, PermissionError):
            pass
        proc.communicate()
        return {"ok": False,
                "error": f"execution exceeded {int(EXEC_TIMEOUT_S)} s wall clock and was killed"}

    result_path = workdir / "_result.json"
    if result_path.is_file():
        try:
            data = json.loads(result_path.read_text(encoding="utf-8"))
            if isinstance(data, dict) and (data.get("ok") or data.get("error")):
                return data
        except (OSError, ValueError):
            pass
    tail = (err or b"")[-2000:].decode("utf-8", "replace").strip()
    return {"ok": False,
            "error": tail or f"harness exited with code {proc.returncode}"}
