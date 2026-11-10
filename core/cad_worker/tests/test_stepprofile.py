"""stepprofile: exact B-rep stats, face histogram, sections and renders.

End-to-end on a STEP built in-test with build123d (same venv as the runner
tests), plus the CLI error path.
"""
import json
import subprocess
import sys
from pathlib import Path

import pytest

pytest.importorskip("build123d")

from build123d import Box, Cylinder, export_step  # noqa: E402

from cad_worker import stepprofile as spf  # noqa: E402

REPO = Path(__file__).resolve().parent.parent


def _plate_with_bore(path: Path):
    part = Box(100, 100, 10) - Cylinder(10, 30)
    export_step(part, str(path))


def test_analyze_plate_with_bore(tmp_path):
    step = tmp_path / "plate.step"
    _plate_with_bore(step)
    result = spf.analyze(str(step))
    assert result["ok"] is True
    stats = result["stats"]
    w, d, h = stats["bbox_size"]
    for got, want in zip((w, d, h), (100, 100, 10)):
        assert got == pytest.approx(want, abs=0.01)
    assert stats["volume"] == pytest.approx(100 * 100 * 10 - 3.14159 * 100 * 10, rel=1e-3)
    assert stats["watertight"] is True
    assert stats["components"] == 1
    ft = stats["face_types"]
    assert ft.get("plane", 0) >= 6
    assert ft.get("cylinder", 0) >= 1
    assert all(v > 0 for v in ft.values())
    assert set(ft) <= set(spf.FACE_KEYS)
    assert len(result["sections"]) == 8 and all(s["loops"] for s in result["sections"])
    assert len(result["renders"]) == 4


def test_cli_ok_line(tmp_path):
    step = tmp_path / "plate.step"
    _plate_with_bore(step)
    proc = subprocess.run(
        [sys.executable, "-m", "cad_worker.stepprofile", str(step)],
        capture_output=True, text=True, cwd=REPO, timeout=60)
    assert proc.returncode == 0
    payload = json.loads(proc.stdout)
    assert payload["ok"] is True
    assert payload["stats"]["face_types"]["cylinder"] >= 1


def test_cli_garbage_exit1(tmp_path):
    bad = tmp_path / "bad.step"
    bad.write_text("this is not a STEP file\n")
    proc = subprocess.run(
        [sys.executable, "-m", "cad_worker.stepprofile", str(bad)],
        capture_output=True, text=True, cwd=REPO, timeout=60)
    assert proc.returncode == 1
    payload = json.loads(proc.stdout)
    assert payload["ok"] is False and payload["error"]
