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

import math
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
    # the geometry assertions are keyed by heading number; a renumbered quickref
    # must not silently disable them
    numbers = {label.split(".", 1)[0] for label, _ in _SML_BLOCKS}
    assert {"1", "2", "3", "5", "6", "7"} <= numbers, (
        f"blocks 1, 2, 3, 5, 6 and 7 not found, got {sorted(numbers)}"
    )


@_SMLIBPY_SKIP
@pytest.mark.parametrize(
    "label,src",
    [(label, body) for label, body in _SML_BLOCKS],
    ids=[f"{i}-{label}" for i, (label, _) in enumerate(_SML_BLOCKS)],
)
def test_smlibpy_quickref_block_builds_a_part(label: str, src: str):
    ns = {"__name__": "__quickref__"}
    exec(src, ns)  # noqa: S102 - repo-owned examples
    part = ns.get("part")
    assert part is not None, "example must end by defining `part`"
    from smlibpy import Part as _Part
    assert isinstance(part, _Part), f"part is {type(part)}, not smlibpy.Part"
    bb = part.bbox()
    sizes = (bb.max.x - bb.min.x, bb.max.y - bb.min.y, bb.max.z - bb.min.z)
    assert all(d > 0 for d in sizes), f"degenerate part: {sizes}"
    _assert_expected_geometry(label, part, sizes)


# "Non-degenerate" is not enough: a blind hole and a thread that is half-buried
# in the shank are both non-degenerate. These blocks carry first-principles
# expectations, keyed by the number in their `## N.` heading.
#
# Block 1: plate 80x60x10, four vertical fillets r=5, one 16 mm bore THROUGH.
#   48000 - 4*(25 - pi*25/4)*10 - pi*8^2*10 = 48000 - 214.60 - 2010.62 = 45774.78
#   (a blind 6 mm bore, i.e. a centred unmoved tool, would give 46579.03)
# Block 2: flange D60 x 12, four D6 holes THROUGH.
#   pi*30^2*12 - 4*pi*3^2*12 = 33929.20 - 1357.17 = 32572.03
#   (blind 7 mm holes would give 33137.52)
# Block 3: bushing revolved about Z (mnft is Z-up, base on Z=0): 16 x 16 x 20,
#   z = 0..20. Revolved about Y it comes out 16 x 20 x 16 at z = -8..8.
# Block 5: M3 thread, crest r=1.5 => 3.0 mm across the threads, and more
#   material than the bare shank pi*1.2^2*8 = 36.19 (a ridge swallowed by the
#   shank returns exactly the shank: bbox 2.4, volume 36.19).
# Blocks 6, 7: M3 screws with a flat head. EXACTLY ONE body (a head revolved about
#   Y floats beside the shank as a second body), base on Z=0 within the 0.2 mm
#   the ridge tube dips below it, 6.0 x 6.0 across the head, and
#   11.2 = 0.2 + 8 + 3 (block 6) / 15.2 = 0.2 + 12 + 3 (block 7) tall.
EXPECTED_VOLUME = {"1": (45774.78, 1.0), "2": (32572.03, 1.0)}
BARE_SHANK_VOLUME = math.pi * 1.2**2 * 8.0
EXPECTED_SIZE = {"3": (16.0, 16.0, 20.0), "6": (6.0, 6.0, 11.2), "7": (6.0, 6.0, 15.2)}
EXPECTED_BODIES = {"3": 1, "6": 1, "7": 1}
SIZE_TOL = 0.05
Z_MIN_TOL = 0.25


def _assert_expected_geometry(label: str, part, sizes) -> None:
    number = label.split(".", 1)[0]
    if number in EXPECTED_VOLUME:
        want, tol = EXPECTED_VOLUME[number]
        assert abs(part.volume - want) <= tol, (
            f"block {number}: volume {part.volume:.3f} != expected {want} +/- {tol}"
        )
    if number in EXPECTED_SIZE:
        want = EXPECTED_SIZE[number]
        assert all(abs(g - w) <= SIZE_TOL for g, w in zip(sizes, want)), (
            f"block {number}: bbox {tuple(round(g, 3) for g in sizes)} != {want} +/- {SIZE_TOL}"
        )
        z_min = part.bbox().min.z
        assert abs(z_min) <= Z_MIN_TOL, (
            f"block {number}: base at z={z_min:.3f}, expected within {Z_MIN_TOL} of 0 "
            "(sideways or detached part?)"
        )
    if number in EXPECTED_BODIES:
        bodies = len(part.solids())
        assert bodies == EXPECTED_BODIES[number], (
            f"block {number}: {bodies} bodies, expected {EXPECTED_BODIES[number]}"
        )
    if number == "5":
        assert abs(sizes[0] - 3.0) <= 0.02, (
            f"block 5: major diameter {sizes[0]:.3f} mm across the threads, expected 3.0"
        )
        assert part.volume > BARE_SHANK_VOLUME, (
            f"block 5: volume {part.volume:.3f} <= bare shank {BARE_SHANK_VOLUME:.3f}"
        )


# The 8 mm / 16-turn thread limit in the prompt and skills rests on a measured
# smlibpy 0.2.3 defect: fusing a swept helical tube onto the shank beyond ~16 turns
# silently returns the bare shank (no error). Canary: the in-code `assert` the blocks
# use must turn that silent loss into a loud failure for a 12 mm thread. If smlibpy
# fixes the fuse this test fails, which is the cue to re-measure and relax the limit.
@_SMLIBPY_SKIP
def test_thread_assert_catches_the_silent_ridge_loss_beyond_16_turns():
    from smlibpy import Align, Circle, Cylinder, Helix, sweep

    length, r_minor = 12.0, 1.2  # 24 turns at pitch 0.5
    shank = Cylinder(r_minor, length, align=(Align.CENTER, Align.CENTER, Align.MIN))
    shank = shank + sweep(Circle(0.2), path=Helix(pitch=0.5, height=length, radius=1.3))
    bb = shank.bbox()
    assert (bb.max.x - bb.min.x) == pytest.approx(2.4, abs=0.02), "ridge survived: re-measure"
    assert shank.volume == pytest.approx(math.pi * r_minor**2 * length, rel=1e-4)
