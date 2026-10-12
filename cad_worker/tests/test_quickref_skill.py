"""Every ```python block in 00-build123d-quickref.md must run and yield a part.

The quickref is injected into every CAD LLM round (Prompt.skills_block), so a
drifted signature there poisons every generation. Each example executes
against the pinned build123d and must define a non-degenerate `part` — the
same contract the worker enforces on generated code.

Discipline ported from pzfreo/build123d-mcp's RUNNABLE_EXAMPLES tests
(Apache-2.0).
"""

import re
from pathlib import Path

import pytest

QUICKREF = (
    Path(__file__).resolve().parents[2]
    / "mnft_cad"
    / "priv"
    / "cad"
    / "skills"
    / "00-build123d-quickref.md"
)
BLOCK_RE = re.compile(r"^```python\n(.*?)^```$", re.DOTALL | re.MULTILINE)
HEADING_RE = re.compile(r"^## (.+)$", re.MULTILINE)


def _labelled_blocks(text: str) -> list[tuple[str, str]]:
    blocks = []
    for m in BLOCK_RE.finditer(text):
        headings = HEADING_RE.findall(text[: m.start()])
        label = headings[-1].strip().lower().replace(" ", "-") if headings else "block"
        blocks.append((label, m.group(1)))
    return blocks


BLOCKS = _labelled_blocks(QUICKREF.read_text())


def test_quickref_has_executable_blocks():
    assert len(BLOCKS) >= 5, f"only {len(BLOCKS)} ```python blocks in {QUICKREF}"


@pytest.mark.parametrize(
    "src",
    [body for _, body in BLOCKS],
    ids=[f"{i}-{label}" for i, (label, _) in enumerate(BLOCKS)],
)
def test_quickref_block_builds_a_part(src: str):
    ns = {"__name__": "__quickref__"}
    exec(src, ns)  # noqa: S102 - repo-owned, dependency-free examples
    part = ns.get("part")
    assert part is not None, "example must end by defining `part`"
    size = part.bounding_box().size
    assert all(d > 0 for d in (size.X, size.Y, size.Z)), f"degenerate part: {size}"
