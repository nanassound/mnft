"""CAM bridge: run one FreeCAD headless CAM job for a STEP + machining plan.

Runs in the worker env (NO FreeCAD import here -- FreeCAD is a separate
process). `run_cam` writes a spec JSON, launches the FreeCAD binary on
`cam_freecad.py`, and reads back the JSON result the script leaves next to
the output. Never raises; every failure lands in {"error": ...}.
"""
from __future__ import annotations

import json
import os
import shutil
import subprocess
from pathlib import Path

DEFAULT_FREECAD = "/Applications/FreeCAD.app/Contents/MacOS/FreeCAD"
DEFAULT_CAM_TIMEOUT_S = 180


def resolve_freecad(cam_cfg: dict | None) -> str | None:
    """The FreeCAD binary to run, or None. Precedence: payload config,
    MNFT_FREECAD_CMD, the macOS bundle default."""
    cmd = (cam_cfg or {}).get("freecad_cmd") or os.environ.get("MNFT_FREECAD_CMD") or DEFAULT_FREECAD
    if not cmd:
        return None
    found = shutil.which(cmd) or (cmd if Path(cmd).is_file() else None)
    return os.path.abspath(found) if found else None


def run_cam(step_path: str, plan: dict, cam_cfg: dict | None, out_dir: str | Path) -> dict:
    """Generate `model.gcode` in `out_dir` from `step_path` + `plan`.

    Returns {"gcode": "model.gcode", "warnings": [...]} on success or
    {"error": "<machine-readable-ish message>"} on failure.
    """
    try:
        cam_cfg = cam_cfg or {}
        freecad = resolve_freecad(cam_cfg)
        if not freecad:
            return {"error": "freecad-not-found: set MNFT_FREECAD_CMD to the FreeCAD binary"}

        toolbits_dir = cam_cfg.get("toolbits_dir") or os.environ.get("MNFT_TOOLBITS_DIR")
        if not toolbits_dir or not Path(toolbits_dir).is_dir():
            return {"error": "cam-toolbits-missing: toolbits dir not found"}

        script = Path(__file__).with_name("cam_freecad.py")
        if not script.is_file():
            return {"error": "cam-script-missing: cam_freecad.py not next to cam.py"}

        timeout_s = float(cam_cfg.get("timeout_s") or os.environ.get("MNFT_CAM_TIMEOUT_S", DEFAULT_CAM_TIMEOUT_S))
        out_dir = Path(out_dir)
        out_dir.mkdir(parents=True, exist_ok=True)
        spec_path = out_dir / "_cam_spec.json"
        result_path = out_dir / "_cam_result.json"

        spec = {
            "step": str(step_path),
            "plan": plan,
            "toolbits_dir": str(toolbits_dir),
            "output": str(out_dir / "model.gcode"),
            "result": str(result_path),
        }
        spec_path.write_text(json.dumps(spec), encoding="utf-8")

        try:
            proc = subprocess.run(
                [freecad, "--console", str(script)],
                env={**os.environ, "MNFT_CAM_SPEC": str(spec_path)},
                stdin=subprocess.DEVNULL,  # --console waits on stdin otherwise
                capture_output=True,
                text=True,
                timeout=timeout_s,
            )
        except subprocess.TimeoutExpired:
            return {"error": f"freecad-cam-timeout: exceeded {timeout_s:.0f}s"}

        if proc.returncode != 0:
            tail = (proc.stderr or proc.stdout or "").strip().splitlines()[-5:]
            return {"error": f"freecad exited {proc.returncode}: " + " | ".join(tail)}

        if not result_path.is_file():
            return {"error": "freecad produced no cam result"}
        result = json.loads(result_path.read_text(encoding="utf-8"))
        if not result.get("ok"):
            return {"error": f"cam failed: {result.get('error', 'unknown')}"}

        gcode = out_dir / "model.gcode"
        if not gcode.is_file() or gcode.stat().st_size == 0:
            return {"error": "cam produced an empty gcode file"}
        return {"gcode": "model.gcode", "warnings": list(result.get("warnings", []))}
    except Exception as exc:  # noqa: BLE001 -- report, never raise
        return {"error": f"cam failure: {type(exc).__name__}: {exc}"}
