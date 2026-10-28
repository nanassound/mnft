"""CLI protocol tests. The static_check path is pure stdlib (no build123d
import); the exec path is exercised by test_runner.py inside the worker venv.
"""
import json
import subprocess
import sys
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parent.parent


def _run(stdin: str, args=()):
    return subprocess.run(
        [sys.executable, "-m", "cad_worker.cli", *args],
        input=stdin, capture_output=True, text=True, cwd=REPO, timeout=30)


def test_static_reject_replies_without_spawning(tmp_path):
    req = json.dumps({"code": "x = 1", "model_dir": str(tmp_path / "m")})
    proc = _run(req + "\n")
    assert proc.returncode == 0, proc.stderr
    reply = json.loads(proc.stdout)
    assert reply == {
        "ok": False, "stage": "static_check",
        "error": "generated code never defines `part`",
        "artifacts": None, "mesh": None, "exec_ms": 0,
    }
    assert not (tmp_path / "m").exists()  # rejected before any dir creation


def test_reply_is_exactly_one_line():
    req = json.dumps({"code": "import os\npart = Box(1,1,1)", "model_dir": "/tmp/x"})
    proc = _run(req + "\n")
    assert proc.stdout.count("\n") == 1


def test_unusable_stdin_fails_with_stderr_only():
    proc = _run("not json\n")
    assert proc.returncode == 2
    assert proc.stdout == ""
    assert "unusable request" in proc.stderr


def test_empty_stdin_fails():
    proc = _run("")
    assert proc.returncode == 2


def test_missing_fields_rejected():
    proc = _run(json.dumps({"code": "part = Box(1,1,1)"}) + "\n")
    assert proc.returncode == 2
