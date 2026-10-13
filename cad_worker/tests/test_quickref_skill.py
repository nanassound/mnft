"""Every ```python block in each dialect's quickref must run and yield a part.

The quickref is injected into every CAD LLM round (Prompt.skills_block), so a
drifted signature there poisons every generation. Each example executes
against the pinned library and must define a non-degenerate `part` — the
same contract the worker enforces on generated code.

Two quickref files:
  mnft_cad/priv/cad/skills/00-build123d-quickref.md     — build123d 0.13
  mnft_cad/priv/cad/skills-smlibpy/00-smlibpy-quickref.md — smlibpy 0.2.3

For build123d the test NEVER skips (it is the production engine).
For smlibpy the test skips when smlibpy is not installed (host-without-extra),
but if it IS installed it must not skip and every block must pass.

Discipline ported from pzfreo/build123d-mcp's RUNNABLE_EXAMPLES tests
(Apache-2.0).
"""

import re
from pathlib import Path

import pytest

# ---------------------------------------------------------------------------
# File locations
# ---------------------------------------------------------------------------

_ROOT = Path(__file__).resolve().parents[2] / "mnft_cad" / "priv" / "cad"

QUICKREFS = {
    "build123d": _ROOT / "skills" / "00-build123d-quickref.md",
    "smlibpy": _ROOT / "skills-smlibpy" / "00-smlibpy-quickref.md",
}

BLOCK_RE = re.compile(r"^```python\n(.*?)^```$", re.DOTALL | re.MULTILINE)
HEADING_RE = re.compile(r"^## (.+)$", re.MULTILINE)


def _labelled_blocks(text: str) -> list[tuple[str, str]]:
    blocks = []
    for m in BLOCK_RE.finditer(text):
        headings = HEADING_RE.findall(text[: m.start()])
        label = headings[-1].strip().lower().replace(" ", "-") if headings else "block"
        blocks.append((label, m.group(1)))
    return blocks


# ---------------------------------------------------------------------------
# Check whether smlibpy is importable
# ---------------------------------------------------------------------------

def _smlibpy_available() -> bool:
    try:
        import smlibpy  # noqa: F401
        return True
    except ImportError:
        return False


# ---------------------------------------------------------------------------
# build123d quickref — NEVER skipped
# ---------------------------------------------------------------------------

_B123_BLOCKS = _labelled_blocks(QUICKREFS["build123d"].read_text())


def test_build123d_quickref_has_executable_blocks():
    assert len(_B123_BLOCKS) >= 5, (
        f"only {len(_B123_BLOCKS)} ```python blocks in {QUICKREFS['build123d']}"
    )


@pytest.mark.parametrize(
    "src",
    [body for _, body in _B123_BLOCKS],
    ids=[f"{i}-{label}" for i, (label, _) in enumerate(_B123_BLOCKS)],
)
def test_build123d_quickref_block_builds_a_part(src: str):
    ns = {"__name__": "__quickref__"}
    exec(src, ns)  # noqa: S102 - repo-owned examples
    part = ns.get("part")
    assert part is not None, "example must end by defining `part`"
    size = part.bounding_box().size
    assert all(d > 0 for d in (size.X, size.Y, size.Z)), f"degenerate part: {size}"


# ---------------------------------------------------------------------------
# smlibpy quickref — skipped when smlibpy is not installed
# ---------------------------------------------------------------------------

_SMLIBPY_SKIP = pytest.mark.skipif(
    not _smlibpy_available(),
    reason="smlibpy not installed (install the [smlibpy] extra to run this suite)",
)

_SML_BLOCKS: list[tuple[str, str]] = []
if _smlibpy_available():
    _SML_BLOCKS = _labelled_blocks(QUICKREFS["smlibpy"].read_text())


@_SMLIBPY_SKIP
def test_smlibpy_quickref_has_executable_blocks():
    assert len(_SML_BLOCKS) >= 5, (
        f"only {len(_SML_BLOCKS)} ```python blocks in {QUICKREFS['smlibpy']}"
    )


@_SMLIBPY_SKIP
@pytest.mark.parametrize(
    "src",
    [body for _, body in _SML_BLOCKS],
    ids=[f"{i}-{label}" for i, (label, _) in enumerate(_SML_BLOCKS)],
)
def test_smlibpy_quickref_block_builds_a_part(src: str):
    ns = {"__name__": "__quickref__"}
    exec(src, ns)  # noqa: S102 - repo-owned examples
    part = ns.get("part")
    assert part is not None, "example must end by defining `part`"
    from smlibpy import Part as _Part
    assert isinstance(part, _Part), f"part is {type(part)}, not smlibpy.Part"
    bb = part.bbox()
    sizes = (bb.max.x - bb.min.x, bb.max.y - bb.min.y, bb.max.z - bb.min.z)
    assert all(d > 0 for d in sizes), f"degenerate part: {sizes}"
