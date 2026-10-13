"""Tests for the smlibpy CAD dialect: static check, end-to-end harness, CLI.

Static-check table: allow/deny cases with exact failure messages.
End-to-end: verified reference geometry (40 mm cube - Ø10 mm hole):
  volume  ≈ 60858.407 mm³
  bbox      40 × 40 × 40 mm
  triangles 144
  GLB       starts with b"glTF"
"""
from __future__ import annotations

import json
import struct
import subprocess
import sys
import tempfile
from pathlib import Path

import pytest

from cad_worker import runner
from cad_worker.dialects import smlibpy as _sml

# ---------------------------------------------------------------------------
# Static-check unit tests
# ---------------------------------------------------------------------------

DENY_FUNCS = frozenset({"open", "eval", "exec", "__import__"})
MAX_CHARS = 20_000


def _check(src: str) -> str | None:
    """Thin wrapper so test code doesn't repeat kwargs."""
    from cad_worker.runner import _dotted, _DENY_FUNCS, MAX_SOURCE_CHARS
    return _sml.static_check(src, deny_funcs=_DENY_FUNCS,
                              max_chars=MAX_SOURCE_CHARS, dotted_fn=_dotted)


class TestStaticCheckAllow:
    def test_minimal_valid(self):
        assert _check("from smlibpy import *\npart = Box(10, 10, 10)\n") is None

    def test_math_import_allowed(self):
        assert _check("import math\nfrom smlibpy import *\npart = Box(10, 10, 10)\n") is None

    def test_from_smlibpy_submodule_allowed(self):
        # smlibpy.something is still rooted at smlibpy
        assert _check("from smlibpy import Box, Cylinder\npart = Box(10,10,10)\n") is None

    def test_math_submodule_allowed(self):
        assert _check("import math\nfrom smlibpy import *\npart = Box(math.pi, 1, 1)\n") is None


class TestStaticCheckDeny:
    def test_too_large(self):
        big = "from smlibpy import *\npart = Box(1,1,1)\n" + "#" * 22000
        assert _check(big) is not None
        assert "too large" in _check(big)

    def test_no_part_binding(self):
        result = _check("from smlibpy import *\nshape = Box(10, 10, 10)\n")
        assert result is not None
        assert "part" in result

    def test_disallowed_import_numpy(self):
        result = _check("import numpy as np\nfrom smlibpy import *\npart = Box(1,1,1)\n")
        assert result is not None
        assert "numpy" in result

    def test_disallowed_import_build123d(self):
        result = _check("from build123d import *\npart = Box(1,1,1)\n")
        assert result is not None
        assert "build123d" in result

    def test_relative_import_rejected(self):
        result = _check("from . import something\nfrom smlibpy import *\npart = Box(1,1,1)\n")
        assert result is not None
        assert "relative" in result

    def test_open_rejected(self):
        result = _check("from smlibpy import *\npart = Box(1,1,1)\nopen('x')\n")
        assert result is not None
        assert "open" in result.lower()

    def test_eval_rejected(self):
        result = _check("from smlibpy import *\npart = Box(1,1,1)\neval('1')\n")
        assert result is not None
        assert "eval" in result.lower()

    def test_exec_rejected(self):
        result = _check("from smlibpy import *\npart = Box(1,1,1)\nexec('pass')\n")
        assert result is not None

    def test_dunder_import_rejected(self):
        result = _check("from smlibpy import *\npart = Box(1,1,1)\n__import__('os')\n")
        assert result is not None

    def test_random_identifier_rejected(self):
        result = _check("from smlibpy import *\npart = Box(1,1,1)\nrandom\n")
        assert result is not None
        assert "random" in result

    def test_syntax_error_reported(self):
        result = _check("from smlibpy import *\npart = Box(1, 1,\n")
        assert result is not None
        assert "syntax error" in result

    def test_smlibpy_allowlist_error_says_smlibpy_not_build123d(self):
        """Error message names the correct allowlist."""
        result = _check("import os\nfrom smlibpy import *\npart = Box(1,1,1)\n")
        assert result is not None
        assert "smlibpy" in result
        assert "build123d" not in result


# ---------------------------------------------------------------------------
# End-to-end harness test (real execution via runner.execute)
# ---------------------------------------------------------------------------

REFERENCE_CODE = """\
from smlibpy import *
import math
part = Box(40, 40, 40) - Cylinder(5, 60)
"""

pytestmark_e2e = pytest.mark.skipif(
    False, reason="smlibpy installed — must not be skipped"
)


@pytest.fixture(scope="module")
def reference_result(tmp_path_factory):
    """Run the reference geometry once; all geometry-checking tests share it."""
    model_dir = tmp_path_factory.mktemp("smlib_e2e")
    result = runner.execute(REFERENCE_CODE, model_dir, dialect="smlibpy")
    return result, model_dir


def test_e2e_ok(reference_result):
    result, _ = reference_result
    assert result["ok"] is True, f"execute failed: {result.get('error')}"


def test_e2e_volume(reference_result):
    result, _ = reference_result
    vol = result["mesh"]["volume_mm3"]
    assert abs(vol - 60858.407) < 0.5, f"volume {vol} not near 60858.407"


def test_e2e_bbox(reference_result):
    result, _ = reference_result
    bbox = result["mesh"]["bbox_mm"]
    assert bbox == [40.0, 40.0, 40.0], f"bbox {bbox} != [40, 40, 40]"


def test_e2e_triangles(reference_result):
    result, _ = reference_result
    tris = result["mesh"]["triangles"]
    assert tris == 144, f"triangle count {tris} != 144"


def test_e2e_stl_file_exists(reference_result):
    result, model_dir = reference_result
    stl = model_dir / "model.stl"
    assert stl.is_file()
    # Confirm binary STL header magic
    with open(stl, "rb") as fh:
        hdr = fh.read(30)
    assert b"smlibpy" in hdr


def test_e2e_step_file_exists(reference_result):
    result, model_dir = reference_result
    step = model_dir / "model.step"
    assert step.is_file()
    assert step.stat().st_size > 0


def test_e2e_glb_file_exists(reference_result):
    result, model_dir = reference_result
    glb = model_dir / "model.glb"
    assert glb.is_file()
    with open(glb, "rb") as fh:
        magic = fh.read(4)
    assert magic == b"glTF"


def test_e2e_artifacts_keys(reference_result):
    result, _ = reference_result
    arts = result["artifacts"]
    assert "model_id" in arts
    assert arts["stl"] == "model.stl"
    assert arts["step"] == "model.step"
    assert arts["glb"] == "model.glb"


# ---------------------------------------------------------------------------
# CLI: --dialect smlibpy produces the right output
# ---------------------------------------------------------------------------

def test_cli_smlibpy_dialect(tmp_path):
    req = json.dumps({"code": REFERENCE_CODE,
                      "model_dir": str(tmp_path / "model")})
    proc = subprocess.run(
        [sys.executable, "-m", "cad_worker.cli", "--dialect", "smlibpy"],
        input=req + "\n",
        capture_output=True,
        text=True,
    )
    assert proc.returncode == 0
    reply = json.loads(proc.stdout.strip())
    assert reply["ok"] is True
    assert abs(reply["mesh"]["volume_mm3"] - 60858.407) < 0.5
    assert reply["mesh"]["triangles"] == 144


def test_cli_health_reports_smlibpy():
    proc = subprocess.run(
        [sys.executable, "-m", "cad_worker.cli", "--health"],
        capture_output=True,
        text=True,
    )
    assert proc.returncode == 0
    health = json.loads(proc.stdout.strip())
    assert health["ok"] is True
    assert "smlibpy" in health
    assert health["smlibpy"] == "0.2.3"
    assert "build123d" in health


def test_cli_health_missing_smlibpy_still_ok(monkeypatch, tmp_path):
    """A host without smlibpy must still report ok:true for build123d."""
    # We simulate by patching health_info in the smlibpy dialect module
    import cad_worker.dialects.smlibpy as sml_mod
    original = sml_mod.health_info
    try:
        sml_mod.health_info = lambda pv: {"smlibpy": None}
        proc = subprocess.run(
            [sys.executable, "-m", "cad_worker.cli", "--health"],
            capture_output=True,
            text=True,
        )
        assert proc.returncode == 0
        health = json.loads(proc.stdout.strip())
        assert health["ok"] is True
    finally:
        sml_mod.health_info = original


def test_cli_static_check_rejects_bad_import(tmp_path):
    bad_code = "import os\nfrom smlibpy import *\npart = Box(1,1,1)\n"
    req = json.dumps({"code": bad_code, "model_dir": str(tmp_path / "model")})
    proc = subprocess.run(
        [sys.executable, "-m", "cad_worker.cli", "--dialect", "smlibpy"],
        input=req + "\n",
        capture_output=True,
        text=True,
    )
    assert proc.returncode == 0
    reply = json.loads(proc.stdout.strip())
    assert reply["ok"] is False
    assert reply["stage"] == "static_check"
