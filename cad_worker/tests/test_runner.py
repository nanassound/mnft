"""Offline unit tests for the runner's static guard and download path guards.

Ported from the PoC's tests/test_runner.py (prune test dropped: retention moved
to the Elixir tier).
"""
import pytest

from cad_worker import runner

GOOD = "from build123d import *\npart = Box(30, 30, 30)"


def test_accepts_simple_part():
    assert runner.static_check(GOOD) is None


def test_accepts_math_import():
    assert runner.static_check("import math\nfrom build123d import *\npart = Cylinder(5, math.pi)") is None


@pytest.mark.parametrize(
    "src",
    [
        "import os\nfrom build123d import *\npart = Box(1, 1, 1)",
        "from sys import path\nfrom build123d import *\npart = Box(1, 1, 1)",
        "import subprocess\npart = Box(1, 1, 1)",
        "import socket\npart = Box(1, 1, 1)",
        "import requests\npart = Box(1, 1, 1)",
        "import urllib.request\npart = Box(1, 1, 1)",
        "import importlib\npart = Box(1, 1, 1)",
        "import ctypes\npart = Box(1, 1, 1)",
        "import pickle\npart = Box(1, 1, 1)",
        "from build123d import *\nopen('/etc/passwd')\npart = Box(1, 1, 1)",
        "from build123d import *\neval('1+1')\npart = Box(1, 1, 1)",
        "from build123d import *\nexec('x=1')\npart = Box(1, 1, 1)",
        "from build123d import *\n__import__('os').getcwd()\npart = Box(1, 1, 1)",
        "import random\nfrom build123d import *\npart = Box(1, 1, 1)",
        "import numpy\npart = Box(1, 1, 1)",  # only build123d/math allowed
    ],
)
def test_rejects_denied_sources(src):
    err = runner.static_check(src)
    assert isinstance(err, str) and err


def test_comments_do_not_trigger_import_check():
    src = "from build123d import *\n# import os would be bad\npart = Box(1, 1, 1)"
    assert runner.static_check(src) is None


# --- AST import validation ----------------------------------------------------

def _src(body: str) -> str:
    return f"from build123d import *\n{body}\npart = Box(1, 1, 1)"


@pytest.mark.parametrize(
    "body",
    [
        "import math as m\npart = Box(m.pi, 1, 1)",                      # import X as Y
        "from math import cos, sin, radians\npart = Box(cos(0), 1, 1)",  # the regression
        "from math import cos as c\npart = Box(c(0), 1, 1)",             # from X import Y as Z
        "from math import *\npart = Box(radians(30), 1, 1)",             # star import
        "from build123d import Box, Cylinder, Pos\npart = Box(1, 1, 1)",  # multi-name build123d
        "import build123d.something\npart = Box(1, 1, 1)",               # submodule, root allowed
        "def helper():\n    import math\n    return math.pi\npart = Box(helper(), 1, 1)",  # nested
    ],
)
def test_accepts_legitimate_imports(body):
    assert runner.static_check(_src(body)) is None


@pytest.mark.parametrize(
    "body,fragment",
    [
        ("import os\npart = Box(1, 1, 1)", "os"),
        ("import os, sys\npart = Box(1, 1, 1)", "os"),
        ("from numpy import array\npart = Box(1, 1, 1)", "numpy"),
        ("import subprocess\npart = Box(1, 1, 1)", "subprocess"),
        ("from . import sibling\npart = Box(1, 1, 1)", "relative"),
    ],
)
def test_rejects_bad_imports(body, fragment):
    err = runner.static_check(_src(body))
    assert isinstance(err, str) and fragment in err


@pytest.mark.parametrize(
    "body",
    [
        "part = open('x')",
        "part = eval('1')",
        "part = exec('x=1')",
        "part = __import__('os')",
        "f = lambda p: open(p)\npart = Box(1, 1, 1)",
        "part = random.uniform(0, 1)",
        "part = Box(1, 1, 1)\nr = random",
    ],
)
def test_rejects_denied_calls(body):
    assert runner.static_check(_src(body))


def test_accepts_random_like_identifiers():
    # exact-identifier semantics: these are ordinary variable names
    assert runner.static_check(_src("my_randomness = 1\npart = Box(my_randomness, 1, 1)")) is None
    assert runner.static_check(_src("randomness = 2\npart = Box(randomness, 1, 1)")) is None


def test_syntax_error_rejected_with_line():
    err = runner.static_check(_src("part = Box(1, 1"))
    assert err and "syntax error" in err and "line" in err


def test_size_cap_still_enforced():
    big = "from build123d import *\npart = Box(1, 1, 1)  # " + "x" * 21000
    err = runner.static_check(big)
    assert err and "too large" in err


def test_rejects_missing_part_binding():
    assert runner.static_check("from build123d import *\nbox = Box(1, 1, 1)")


# --- harness math pre-binding (needs build123d: runs inside the worker venv) ---

def test_execute_bare_math_names_without_import(tmp_path):
    """A forgotten `import math` must not break an otherwise-good script."""
    pytest.importorskip("build123d")
    src = ("from build123d import *\n"
           "part = Box(sin(pi / 6) * 20, 10, 5)")  # bare sin/pi, no import
    res = runner.execute(src, tmp_path / "m1")
    assert res["ok"], res["error"]
    bbox = res["mesh"]["bbox_mm"]
    assert abs(bbox[0] - 10.0) < 0.1 and abs(bbox[1] - 10.0) < 0.1 and abs(bbox[2] - 5.0) < 0.1


def test_execute_explicit_math_import_still_works(tmp_path):
    """A script that imports math itself simply rebinds — same result."""
    pytest.importorskip("build123d")
    src = ("from build123d import *\n"
           "import math\n"
           "part = Cylinder(math.pi, 1)")
    res = runner.execute(src, tmp_path / "m2")
    assert res["ok"], res["error"]
    bbox = res["mesh"]["bbox_mm"]
    assert abs(bbox[0] - 2 * 3.14159) < 0.01 and abs(bbox[1] - 2 * 3.14159) < 0.01
    assert abs(bbox[2] - 1.0) < 0.01


def test_static_check_still_refuses_disallowed_sources():
    assert runner.static_check("from build123d import *\nopen('x')\npart = Box(1, 1, 1)")
    assert runner.static_check("import os\npart = Box(1, 1, 1)")


# --- download path guards ------------------------------------------------------

@pytest.mark.parametrize(
    "mid,ok",
    [
        ("0123abcd", True),
        ("a" * 32, True),
        ("ABCDEF01", False),  # uppercase not hex per guard
        ("abc", False),  # too short
        ("a" * 33, False),  # too long
        ("zzzzzzzz", False),  # not hex
        ("..", False),
        ("../../etc/passwd", False),
        ("", False),
    ],
)
def test_model_id_guard(mid, ok):
    assert runner.valid_model_id(mid) is ok


@pytest.mark.parametrize(
    "name,ok",
    [
        ("model.stl", True),
        ("model.step", True),
        ("model.glb", True),
        ("model.obj", False),
        ("_user_code.py", False),
        ("_result.json", False),
        ("../_user_code.py", False),
        ("../../etc/passwd", False),
        ("", False),
    ],
)
def test_filename_whitelist(name, ok):
    assert runner.valid_filename(name) is ok


def test_error_summary_leads_with_exception_line():
    tb = (
        "Traceback (most recent call last):\n"
        '  File "/data/models/<id>/_harness.py", line 15, in <module>\n'
        '    exec(compile(src, "generated_code.py", "exec"), ns)\n'
        '  File "generated_code.py", line 22, in <module>\n'
        '  File ".../build123d/build_common.py", line 1535, in call\n'
        "RuntimeError: BuildPart doesn't have a Helix object or operation "
        "(Helix applies to ['BuildLine'])"
    )
    headline = runner.error_summary(tb)
    assert headline.startswith("RuntimeError: BuildPart doesn't have a Helix")
    assert "Traceback" not in headline


def test_error_summary_single_line_passthrough():
    assert runner.error_summary("generated code never defines `part`") == \
        "generated code never defines `part`"


def test_error_summary_empty_and_none():
    assert runner.error_summary("") == "unknown error"
    assert runner.error_summary(None) == "unknown error"
