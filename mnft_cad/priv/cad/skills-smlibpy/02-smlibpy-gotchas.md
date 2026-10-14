<!-- Upstream text: MIT, © AWV Informatik AG (https://github.com/awv-informatik/smlibpy). -->
<!-- Adapted for mnft; derived from SKILL.md in the smlibpy skill package -->

# smlibpy gotchas

## The two silent traps (they return `ok` and a wrong part)

- **A swept thread ridge is silently dropped above ~16 turns.** Fusing
  `sweep(Circle(t), path=Helix(...))` onto the shank returns the bare shank — no error,
  no warning — once the helix has more than about 16 turns. M3, pitch 0.5, minor radius
  1.2, ridge `t = 0.2`, `r_mid = 1.3`: **8 mm (16 turns) keeps the thread** (volume 49.80,
  bbox 3.0 across the threads); **9, 10, 11 and 12 mm (18-24 turns) lose it** (volume =
  π·1.2²·L, bbox 2.4, a smooth rod). Keep the thread ≤ 8 mm; a longer screw gets an 8 mm
  thread plus a plain shank. Splitting a longer thread into fused segments is unreliable
  (8+8 and 4+8 fused cleanly; 8+4, 8+6, 5+5 raised a `KernelError` or left gaps), so
  do not. Check every thread with an `assert` on the threaded shank, before the head or
  anything wider is fused on: bbox across the threads ≈ the major diameter (M3 → 3.0,
  2.4 = ridge lost) and volume > π·r_minor²·L. If it fails, shorten the thread and
  say so in the reply.
- **Revolve about Y (or with no axis) gives a Y-axis part.** mnft models are Z-up with the
  base on Z=0. `profile.revolve(Axis((0, 0, 0), (0, 1, 0)))` or a bare `.revolve()` makes a
  part whose axis is Y: a disc lying sideways at z = −r..+r, detached from a shank built
  along Z. Use the lathe idiom: half profile in XY with x = radius, y = height, then
  `profile.on(Plane.XZ).revolve(Z)` — always pass the axis. Check: base at z ≈ 0, bbox Z =
  profile height, and `len(part.solids()) == 1` after fusing a revolved head to a shank.

## Imports

- **Do not import build123d.** Models default to `from build123d import *` out of habit.
  Here it fails before your code runs: `import not allowed: build123d (only smlibpy and
  math)`, and the turn wastes a repair round trip. The first line is always
  `from smlibpy import *` (then `import math`); no build123d name exists in this engine.

## Method-style vs free functions

`fillet`, `chamfer`, `shell`, `mirror`, `split`, `section` are **methods** on the shape object:

- `part.fillet(edges, r)` ✓
- `fillet(part, edges, r)` ✗ — raises `NameError: name 'fillet' is not defined`

## No module-level fuse()

There is no `fuse(a, b)` free function. Use `a + b` or `a.fuse(b)`.

## Face/edge selection — never by index

Always select by geometry:

- `part.faces().top()` / `.bottom()` / `.largest()`
- `part.edges().parallel_to(Z)` / `.concave()` / `.convex()`
- `part.vertices().top()`

Indices change whenever the model changes. Index selection is always wrong.

## ModelingError vs KernelError

- `ModelingError` — the input cannot work (radius too large, crossing profile, zero-thickness wall). Read the hint; fix the input.
- `KernelError` — the kernel failed on otherwise valid input. Simplify and retry; if it persists, report the geometry.

## Fillet-too-large error

When `.fillet(edges, r)` raises `ModelingError`, the radius exceeds the shortest adjacent edge. Reduce `r`, or select fewer edges.

## Threaded parts — never fillet the ridge

After `sweep(profile, path=helix)`, the ridge has many tiny faces. Calling `.fillet()` or `.chamfer()` on the resulting solid is expensive and will crash. Cut chamfers with a revolved triangular profile instead.

## Hole tools: centred at the origin, but the part sits on Z=0

Primitives are centred, and mnft puts the base on Z=0. `plate -= Cylinder(4, 10)` on a
10 mm plate based at Z=0 reaches only z = +5: a BLIND hole with a skin on top. Reposition
the tool to mid-height and make it taller than the part:
`plate -= Cylinder(4, t + 4).moved(Pos(x, y, t / 2))` (or `align=(Align.CENTER, Align.CENTER,
Align.MIN)` with a below-zero offset). Check: a through hole removes π·r²·t.

## Thread ridge via sweep — the PATH carries the offset

`sweep` centres the profile on the start of the path; `profile.moved(Pos(r, 0, 0))` is a
no-op. Set the helix radius to `crest − t` for a tube of radius `t`:

- The tube must OVERLAP the shank, so `t` must be larger than half the thread height
  (crest − shank radius). A tangent tube (`radius = r_minor + t`) is refused:
  `KernelError: fuse failed (SM_ERR): the operands may touch only along an edge, at a point
  or tangentially (move one so they overlap)`.
- Other tube sizes can "succeed" yet silently return the bare shank (measured for M3,
  pitch 0.5, crest 1.5: `t=0.23`, `0.24`, `0.26` and `0.3` all gave bbox 2.4 and volume 36.19
  = the cylinder alone). Stay with the verified `t = 0.2, r_mid = 1.3`, and for any other
  thread check the result: `bbox` across the threads must read ≈ the major diameter (3.0
  for M3) and the volume must exceed the bare shank's π·r_minor²·length (36.19).

## Volume sanity check

After each step: `print(round(part.volume, 3), part.is_valid())`. Volume 0 or absurdly large means the boolean or align is wrong.
