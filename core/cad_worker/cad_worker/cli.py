"""CLI entry point: the Elixir <-> Python boundary.

Protocol (one shot per process, line oriented):

- `cad-worker --health`
    prints one JSON line `{"ok": true, "build123d": "...", "python": "..."}`
    and exits 0. build123d is imported lazily here only.

- `cad-worker` (stdin): reads one JSON line `{"code": str, "model_dir": str}`
    and replies with exactly one JSON line on stdout:
    `{"ok", "stage", "error", "artifacts", "mesh", "exec_ms"}`.
    `stage` is `"static_check"` (request rejected before any execution) or
    `"exec"`. Exit code is 0 whenever a reply line was produced; nonzero (with
    a message on stderr, nothing on stdout) only for unusable stdin.

A SIGALRM hard-deadline (exec timeout + 5 s) kills the whole process group so a
stuck harness can never outlive the Elixir-side wall clock.
"""
from __future__ import annotations

import json
import os
import signal
import sys
from pathlib import Path

from . import runner


def _arm_hard_deadline() -> None:
    deadline_s = int(runner.EXEC_TIMEOUT_S) + 5

    def _die(_sig, _frame):
        # Last resort: execute()'s own communicate() timeout + killpg already
        # handles the harness; this alarm fires only if the runner wedges.
        os.kill(os.getpid(), signal.SIGKILL)

    signal.signal(signal.SIGALRM, _die)
    signal.alarm(deadline_s)


def _reply(payload: dict) -> None:
    sys.stdout.write(json.dumps(payload) + "\n")
    sys.stdout.flush()


def _health() -> int:
    import sys as _sys
    python_ver = _sys.version.split()[0]
    from .dialects import build123d as _b123d
    from .dialects import smlibpy as _sml
    info: dict = {"ok": True}
    info.update(_b123d.health_info(python_ver))
    info.update(_sml.health_info(python_ver))
    info["python"] = python_ver
    _reply(info)
    return 0


def _run_request(line: str, dialect: str = "build123d") -> int:
    try:
        req = json.loads(line)
        code = req["code"]
        model_dir = req["model_dir"]
        if not isinstance(code, str) or not isinstance(model_dir, str):
            raise ValueError("code and model_dir must be strings")
    except (ValueError, KeyError, TypeError) as exc:
        sys.stderr.write(f"unusable request: {type(exc).__name__}: {exc}\n")
        return 2

    reject = runner.static_check(code, dialect=dialect)
    if reject:
        _reply({"ok": False, "stage": "static_check", "error": reject,
                "artifacts": None, "mesh": None, "exec_ms": 0})
        return 0

    _arm_hard_deadline()
    result = runner.execute(code, Path(model_dir), dialect=dialect)
    _reply({"ok": result["ok"], "stage": "exec",
            "error": result.get("error"),
            "artifacts": result.get("artifacts"),
            "mesh": result.get("mesh"),
            "exec_ms": result.get("exec_ms", 0)})
    return 0


def main() -> int:
    args = sys.argv[1:]
    dialect = "build123d"
    if "--dialect" in args:
        idx = args.index("--dialect")
        dialect = args[idx + 1] if idx + 1 < len(args) else "build123d"

    if "--health" in args:
        return _health()

    line = sys.stdin.readline()
    if not line.strip():
        sys.stderr.write("no request on stdin\n")
        return 2
    return _run_request(line, dialect)


if __name__ == "__main__":
    sys.exit(main())
