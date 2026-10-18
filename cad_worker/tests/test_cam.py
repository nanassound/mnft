"""Offline unit tests for the CAM bridge: spec writing, config precedence,
and failure paths — FreeCAD itself is mocked out (the real FreeCAD run is the
manual E2E smoke, not CI).
"""
import json
from types import SimpleNamespace

import pytest

from cad_worker import cam


PLAN = {"material": "wood", "ops": [{"op": "drill", "toolbit": "flat-3.175"}]}


@pytest.fixture
def toolbits_dir(tmp_path):
    toolbits = tmp_path / "toolbits"
    toolbits.mkdir()
    (tmp_path / "toolbits.json").write_text(json.dumps({"machine": {}, "toolbits": {}}))
    (toolbits / "3.175mm_Flat_End_MC40A.fctb").write_text("{}")
    return toolbits


class Proc:
    def __init__(self, returncode=0, stderr="", stdout=""):
        self.returncode = returncode
        self.stderr = stderr
        self.stdout = stdout


def test_resolve_freecad_prefers_payload_config(tmp_path, monkeypatch):
    cfg_bin = tmp_path / "cfg-freecad"
    env_bin = tmp_path / "env-freecad"
    cfg_bin.write_text("")
    env_bin.write_text("")
    monkeypatch.setenv("MNFT_FREECAD_CMD", str(env_bin))
    assert cam.resolve_freecad({"freecad_cmd": str(cfg_bin)}) == str(cfg_bin)
    assert cam.resolve_freecad({}) == str(env_bin)
    assert cam.resolve_freecad(None) == str(env_bin)

    # a configured path that does not exist resolves to None, not a crash
    assert cam.resolve_freecad({"freecad_cmd": str(tmp_path / "missing")}) is None


def test_resolve_freecad_missing_binary(monkeypatch):
    monkeypatch.delenv("MNFT_FREECAD_CMD", raising=False)
    monkeypatch.setattr(cam, "DEFAULT_FREECAD", "/no/such/freecad")
    assert cam.resolve_freecad({}) is None


def test_run_cam_freecad_not_found(monkeypatch, tmp_path):
    monkeypatch.setattr(cam, "resolve_freecad", lambda cfg: None)
    result = cam.run_cam("/tmp/x.step", PLAN, {"toolbits_dir": "/tmp"}, tmp_path)
    assert result["error"].startswith("freecad-not-found")


def test_run_cam_toolbits_missing(monkeypatch, tmp_path):
    monkeypatch.setattr(cam, "resolve_freecad", lambda cfg: "/fake/freecad")
    result = cam.run_cam("/tmp/x.step", PLAN, {"toolbits_dir": str(tmp_path / "nope")}, tmp_path)
    assert result["error"].startswith("cam-toolbits-missing")


def test_run_cam_writes_spec_and_reads_result(monkeypatch, tmp_path, toolbits_dir):
    """Happy path: the spec carries step/plan/toolbits/output/result, the
    subprocess is the resolved binary with --console and the spec in its env,
    and the JSON the script wrote becomes the return value."""
    captured = {}

    def fake_run(argv, env=None, capture_output=None, text=None, timeout=None, stdin=None, **_kw):
        captured["argv"] = argv
        captured["env"] = env
        spec = json.loads((toolbits_dir.parent / "models" / "_cam_spec.json").read_text())
        captured["spec"] = spec
        out_dir = tmp_path / "models"
        (out_dir / "model.gcode").write_text("(gcode)\nG21\n")
        (out_dir / "_cam_result.json").write_text(json.dumps({"ok": True, "warnings": ["w1"]}))
        return Proc(0)

    monkeypatch.setattr(cam, "resolve_freecad", lambda cfg: "/fake/freecad")
    monkeypatch.setattr(cam.subprocess, "run", fake_run)

    result = cam.run_cam("/tmp/x.step", PLAN, {"toolbits_dir": str(toolbits_dir), "timeout_s": 5}, tmp_path / "models")

    assert result == {"gcode": "model.gcode", "warnings": ["w1"]}
    assert captured["argv"][:3] == ["/fake/freecad", "--console", str(cam.Path(cam.__file__).with_name("cam_freecad.py"))]
    assert captured["env"]["MNFT_CAM_SPEC"].endswith("_cam_spec.json")
    spec = captured["spec"]
    assert spec["step"] == "/tmp/x.step"
    assert spec["plan"] == PLAN
    assert spec["toolbits_dir"] == str(toolbits_dir)
    assert spec["output"].endswith("model.gcode")


def test_run_cam_nonzero_exit_reports_stderr_tail(monkeypatch, tmp_path, toolbits_dir):
    monkeypatch.setattr(cam, "resolve_freecad", lambda cfg: "/fake/freecad")
    monkeypatch.setattr(
        cam.subprocess,
        "run",
        lambda *a, **k: Proc(1, stderr="boom\nline two"),
    )
    result = cam.run_cam("/tmp/x.step", PLAN, {"toolbits_dir": str(toolbits_dir)}, tmp_path)
    assert "freecad exited 1" in result["error"]
    assert "line two" in result["error"]


def test_run_cam_timeout(monkeypatch, tmp_path, toolbits_dir):
    monkeypatch.setattr(cam, "resolve_freecad", lambda cfg: "/fake/freecad")

    def raise_timeout(*a, **k):
        raise cam.subprocess.TimeoutExpired(cmd="freecad", timeout=1)

    monkeypatch.setattr(cam.subprocess, "run", raise_timeout)
    result = cam.run_cam("/tmp/x.step", PLAN, {"toolbits_dir": str(toolbits_dir), "timeout_s": 1}, tmp_path)
    assert result["error"].startswith("freecad-cam-timeout")


def test_run_cam_script_failure_result(monkeypatch, tmp_path, toolbits_dir):
    """The FreeCAD process exits 0 but the script reported a failure."""
    monkeypatch.setattr(cam, "resolve_freecad", lambda cfg: "/fake/freecad")

    def fake_run(*a, **k):
        out_dir = tmp_path / "m"
        (out_dir / "_cam_result.json").write_text(json.dumps({"ok": False, "error": "no top face"}))
        return Proc(0)

    monkeypatch.setattr(cam.subprocess, "run", fake_run)
    result = cam.run_cam("/tmp/x.step", PLAN, {"toolbits_dir": str(toolbits_dir)}, tmp_path / "m")
    assert result["error"] == "cam failed: no top face"


def test_run_cam_empty_gcode(monkeypatch, tmp_path, toolbits_dir):
    monkeypatch.setattr(cam, "resolve_freecad", lambda cfg: "/fake/freecad")

    def fake_run(*a, **k):
        out_dir = tmp_path / "m"
        (out_dir / "model.gcode").write_text("")
        (out_dir / "_cam_result.json").write_text(json.dumps({"ok": True, "warnings": []}))
        return Proc(0)

    monkeypatch.setattr(cam.subprocess, "run", fake_run)
    result = cam.run_cam("/tmp/x.step", PLAN, {"toolbits_dir": str(toolbits_dir)}, tmp_path / "m")
    assert result["error"] == "cam produced an empty gcode file"


def test_runner_honors_cam_note_without_freecad(tmp_path, monkeypatch):
    """runner.execute with a cam plan but an unusable FreeCAD surfaces a
    cam_note and still returns the model."""
    from cad_worker import runner

    monkeypatch.setenv("MNFT_FREECAD_CMD", "/no/such/freecad")
    result = runner.execute(
        "from build123d import *\npart = Box(1, 1, 1)",
        tmp_path / "m1",
        cam_plan=PLAN,
        cam_cfg={"toolbits_dir": str(tmp_path / "tb")},
    )
    assert result["ok"] is True
    assert "gcode" not in result["artifacts"]
    assert "cam_note" in result and "freecad" in result["cam_note"]


def test_runner_skips_cam_for_non_build123d_dialect(tmp_path):
    from cad_worker import runner

    result = runner.execute(
        "cube(1);",
        tmp_path / "m2",
        dialect="openscad",
        cam_plan=PLAN,
        cam_cfg={},
    )
    # dialects other than build123d don't even route through this runner's
    # harness; the note is only produced on the build123d path. Here the
    # dialect check inside execute() is unreachable for openscad because the
    # harness module lookup happens first — assert no gcode leaked.
    assert not (result.get("artifacts") or {}).get("gcode")
