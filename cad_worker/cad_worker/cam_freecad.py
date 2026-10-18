"""FreeCAD headless CAM: one STEP + a machining plan -> GRBL G-code.

Executed as ``<freecad> --console cam_freecad.py`` with the spec path in the
``MNFT_CAM_SPEC`` env var (argv fallback: ``-- <spec.json>``). Spec:

    {"step": str, "plan": {...}, "toolbits_dir": str,
     "output": str, "result": str, "machine": {...}}

Writes the G-code to `output` and a JSON result to `result`:
    {"ok": true, "warnings": [...]}  or  {"ok": false, "error": "..."}

Determinism: the plan names ops and toolbit ids; THIS module decides which
faces/edges each op receives (largest +Z planar face = top, +Z planar faces
below it = pocket floors, full-circle edges = holes). Tool geometry comes
from the vendored .fctb files via FreeCAD's ToolBit loader; feeds/plunge/
RPM/stepdown come from toolbits.json for the plan's material.

Coordinate convention of the output: part XY origin = bbox min corner,
Z0 = stock top (the shape is translated accordingly before the job is
built), so the machinist can touch off on the stock top and corner.
"""
import json
import math
import os
import pathlib
import sys

import FreeCAD as App
import Part
import Path  # noqa: F401 -- registers the CAM workbench
import Path.Main.Job as PathJob
from Path.Op import Drilling, MillFace, Pocket, Profile
from Path.Post.Processor import PostProcessorFactory
from Path.Tool import Controller as ToolControllerMod
from Path.Tool.toolbit import ToolBit

TOL = 0.1  # mm: parallelism / below-top tolerance

_OP_MODULES = {"face": MillFace, "pocket": Pocket, "profile": Profile, "drill": Drilling}


def _read_spec():
    raw = os.environ.get("MNFT_CAM_SPEC")
    if not raw:
        args = sys.argv[1:]
        if "--" in args:
            args = args[args.index("--") + 1:]
        raw = next((a for a in args if a.endswith(".json")), None)
    if not raw:
        raise SystemExit("no spec: set MNFT_CAM_SPEC or pass `-- <spec.json>`")
    return json.loads(pathlib.Path(raw).read_text(encoding="utf-8"))


def _fail(result_path, error):
    pathlib.Path(result_path).write_text(json.dumps({"ok": False, "error": error}), encoding="utf-8")


def _finish(result_path, warnings):
    pathlib.Path(result_path).write_text(json.dumps({"ok": True, "warnings": warnings}), encoding="utf-8")


def _face_normal(f):
    u0, u1, v0, v1 = f.ParameterRange
    # normalAt() accounts for face orientation: it returns the OUTWARD normal
    # (verified against top/bottom faces of an imported STEP)
    n = f.normalAt((u0 + u1) / 2.0, (v0 + v1) / 2.0)
    return App.Vector(n.x, n.y, n.z).normalize()


def _planar_faces(shape):
    return [(i, f) for i, f in enumerate(shape.Faces) if f.Surface.__class__.__name__ == "Plane"]


def _orient_z_up(shape):
    """Rotate so the largest vertical planar face looks at +Z. build123d
    models are already Z-up (base on Z=0); this is a safety net for imports
    whose top is on -Z or sideways."""
    planar = _planar_faces(shape)
    if not planar:
        return
    vertical = [(i, f) for i, f in planar if abs(_face_normal(f).z) > 1 - 1e-6]
    _, face = max(vertical or planar, key=lambda t: t[1].Area)
    rot = App.Rotation(_face_normal(face), App.Vector(0, 0, 1))
    if rot.Angle > 1e-9:
        shape.rotate(App.Vector(0, 0, 0), rot.Axis, math.degrees(rot.Angle))


def _circle_edges(shape):
    """Full-circle edges with a Z axis: [(edge_index, radius, center_z)]."""
    out = []
    for i, e in enumerate(shape.Edges):
        c = e.Curve
        if c.__class__.__name__ != "Circle" or abs(abs(c.Axis.z) - 1) > 1e-6:
            continue
        out.append((i, c.Radius, c.Center.z))
    return out


def _toolbit_entries(toolbits_dir, plan):
    """toolbit id -> {spec, attrs, feeds} for the plan's material, one .fctb
    load per distinct id."""
    cfg_path = pathlib.Path(toolbits_dir).joinpath("..", "toolbits.json").resolve()
    cfg = json.loads(cfg_path.read_text(encoding="utf-8"))
    known = cfg["toolbits"]
    material = plan["material"]
    entries = {}
    for op in plan["ops"]:
        tid = op["toolbit"]
        if tid not in entries:
            if tid not in known:
                raise ValueError(f"unknown toolbit id: {tid}")
            spec = known[tid]
            attrs = json.loads((pathlib.Path(toolbits_dir) / spec["fctb"]).read_text(encoding="utf-8"))
            if material not in spec["feeds"]:
                raise ValueError(f"toolbit {tid} has no {material} feeds")
            entries[tid] = {"spec": spec, "attrs": attrs, "feeds": spec["feeds"][material]}
    return cfg["machine"], entries


def run(spec):
    plan = spec["plan"]
    toolbits_dir = spec["toolbits_dir"]
    result_path = spec["result"]
    warnings = []

    try:
        machine, entries = _toolbit_entries(toolbits_dir, plan)
    except Exception as exc:  # noqa: BLE001 -- report, never crash
        return _fail(result_path, f"toolbit lookup failed: {exc}")

    shape = Part.Shape()
    shape.read(str(spec["step"]))
    _orient_z_up(shape)

    env = machine.get("work_envelope_mm", [300, 180, 45])
    bb = shape.BoundBox
    if bb.XLength > env[0] + 0.5 or bb.YLength > env[1] + 0.5 or bb.ZLength > env[2] + 0.5:
        warnings.append(
            f"model {bb.XLength:.1f}x{bb.YLength:.1f}x{bb.ZLength:.1f} mm exceeds "
            f"the work envelope {env[0]}x{env[1]}x{env[2]} mm"
        )
    if plan["material"] == "aluminum":
        warnings.append("aluminum: use mist lubrication; feeds are conservative — listen for chatter")

    # origin: part XY min corner, Z0 = stock top
    shape.translate(App.Vector(-bb.XMin, -bb.YMin, -bb.ZMax))
    top_z = shape.BoundBox.ZMax  # 0 by construction
    z_min = shape.BoundBox.ZMin

    doc = App.newDocument("mnft_cam")
    App.setActiveDocument(doc.Name)
    model = doc.addObject("Part::Feature", "mnft_model")
    model.Shape = shape

    planar = _planar_faces(shape)
    tops = [(i, f) for i, f in planar
            if _face_normal(f).z > 1 - 1e-6 and abs(f.BoundBox.ZMax - top_z) < TOL]
    if not tops:
        return _fail(result_path, "no +Z planar top face found")
    top_idx, _top_face = max(tops, key=lambda t: t[1].Area)

    pockets = [(i, f) for i, f in planar
               if _face_normal(f).z > 1 - 1e-6 and f.BoundBox.ZMax < top_z - TOL]

    tools = {}     # toolbit id -> (tc, feeds, rpm)
    op_specs = []  # (op_module_name, toolbit_id, base, start_z, final_z, peck_mm)

    def tc_for(tid):
        if tid not in tools:
            entry = entries[tid]
            feeds = entry["feeds"]
            tb = ToolBit.from_dict(entry["attrs"])
            doc_obj = tb.attach_to_doc(doc)
            tc = ToolControllerMod.Create(f"TC: {tid}", tool=doc_obj, toolNumber=len(tools) + 1)
            rpm = min(float(feeds.get("rpm", machine["spindle_rpm_max"])), machine["spindle_rpm_max"])
            tc.HorizFeed = App.Units.Quantity(f"{float(feeds['feed'])} mm/min")
            tc.VertFeed = App.Units.Quantity(f"{float(feeds['plunge'])} mm/min")
            tc.HorizRapid = App.Units.Quantity("3000 mm/min")
            tc.VertRapid = App.Units.Quantity("3000 mm/min")
            tc.SpindleSpeed = rpm
            tc.SpindleDir = "Forward"
            tools[tid] = (tc, feeds, int(rpm))
        return tools[tid]

    for op in plan["ops"]:
        kind, tid = op["op"], op["toolbit"]
        _tc, feeds, _ = tc_for(tid)
        dia = float(str(entries[tid]["attrs"]["parameter"]["Diameter"]).split()[0])

        if kind == "face":
            op_specs.append((kind, tid, [(model, f"Face{top_idx + 1}")],
                             top_z, top_z - float(feeds.get("stepdown", 0.5)), None))
        elif kind == "pocket":
            if not pockets:
                warnings.append("pocket requested but the model has no recessed planar face — op skipped")
                continue
            for i, f in pockets:
                across = min(f.BoundBox.XLength, f.BoundBox.YLength)
                if across < dia:
                    warnings.append(
                        f"pocket floor Face{i + 1} ({across:.1f} mm across) is narrower "
                        f"than the {dia} mm tool — it will not clear fully"
                    )
                op_specs.append((kind, tid, [(model, f"Face{i + 1}")], top_z, f.BoundBox.ZMin, None))
        elif kind == "profile":
            op_specs.append((kind, tid, [(model, f"Face{top_idx + 1}")], top_z, z_min, None))
            if bb.XLength + 2 * dia > env[0] or bb.YLength + 2 * dia > env[1]:
                warnings.append("the profile pass plus tool offset may exceed the work envelope")
        elif kind == "drill":
            floors = {f.BoundBox.ZMax for _i, f in pockets}
            circles = [c for c in _circle_edges(shape)
                       if abs(c[2] - top_z) < TOL or any(abs(c[2] - fz) < TOL for fz in floors)]
            if not circles:
                warnings.append("drill requested but the model has no holes — op skipped")
                continue
            groups = {}
            for idx, r, _z in circles:
                groups.setdefault(round(r, 2), []).append(idx)
            for r, idxs in groups.items():
                if 2 * r < dia:
                    warnings.append(
                        f"hole diameter {2 * r:.1f} mm is smaller than the {dia} mm "
                        f"tool — it will be marked, not cut"
                    )
                elif 2 * r - dia > 1.0:
                    warnings.append(
                        f"hole diameter {2 * r:.1f} mm drilled with the {dia} mm "
                        f"tool stays {2 * r - dia:.1f} mm undersized"
                    )
                base = [(model, f"Edge{i + 1}") for i in idxs]
                op_specs.append((kind, tid, base, top_z, z_min, op.get("peck_mm")))

    if not op_specs:
        return _fail(result_path, "no op in the plan produced any geometry")

    job = PathJob.Create("Job", [model], None)
    job.PostProcessor = machine.get("post", "grbl")
    job.PostProcessorArgs = ""
    doc.recompute()

    for kind, tid, base, start_z, final_z, peck in op_specs:
        tc, feeds, _ = tools[tid]
        op = _OP_MODULES[kind].Create(kind.capitalize(), None, job)
        op.ToolController = tc
        op.Base = base
        # ops bind depths to Op* placeholders via ExpressionEngine; clear the
        # bindings or the recompute overwrites the plain values set below
        for prop in ("StartDepth", "FinalDepth", "PeckDepth", "StepDown"):
            try:
                op.setExpression(prop, None)
            except Exception:  # noqa: BLE001 -- property not bindable on this op
                pass
        op.StartDepth = start_z
        op.FinalDepth = final_z
        if kind in ("face", "pocket", "profile") and feeds.get("stepdown"):
            op.StepDown = App.Units.Quantity(f"{float(feeds['stepdown'])} mm")
        if kind == "drill" and peck:
            op.PeckEnabled = True
            op.PeckDepth = App.Units.Quantity(f"{float(peck)} mm")
        doc.recompute()

    doc.recompute()
    post = machine.get("post", "grbl")
    processor = PostProcessorFactory.get_post_processor(job, post)
    if processor is None:
        return _fail(result_path, f"post processor {post!r} not available")
    sections = processor.export()
    gcode = "".join(g for _name, g in sections if g)

    header_lines = [
        "mnft CNC export",
        f"material: {plan['material']} | post: {post}",
        "origin: part XY min corner, Z0 = stock top",
        "ops: " + " -> ".join(f"{k}({t})" for k, t, *_ in op_specs),
    ]
    for tid, (tc, feeds, rpm) in tools.items():
        header_lines.append(
            f"tool {tid}: D={tc.Tool.Diameter} rpm={rpm} "
            f"feed={feeds['feed']} plunge={feeds['plunge']} mm/min"
        )
    for w in warnings:
        header_lines.append(f"warning: {w}")
    gcode = "".join(f"({line})\n" for line in header_lines) + gcode

    pathlib.Path(spec["output"]).write_text(gcode, encoding="utf-8")
    return _finish(result_path, warnings)


# FreeCAD console executes script files with __name__ != "__main__": run at
# top level, never raise past this point.
_spec = _read_spec()
try:
    run(_spec)
except Exception as exc:  # noqa: BLE001
    import traceback

    _fail(_spec["result"], f"{type(exc).__name__}: {exc}: {traceback.format_exc()[-1500:]}")
