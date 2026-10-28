# build123d quick reference
<!-- Adapted from pzfreo/build123d-mcp quickref.py (Apache-2.0). Every fenced
python block below is test-executed against the pinned build123d by
cad_worker/tests/test_quickref_skill.py — keep each block a complete program
that ends by defining `part`. -->

build123d 0.13, lengths in mm. End with a variable named `part` (the worker
exports it).

## Two patterns

Algebra mode — operators compose shapes, no context managers:

```python
from build123d import *
part = Box(20, 10, 5) - Cylinder(3, 6).move(Location((5, 0, 0)))
```

Builder mode — BuildPart context; each op takes `mode=`:

```python
from build123d import *
with BuildPart() as p:
    Box(20, 10, 5)
    Cylinder(3, 6, mode=Mode.SUBTRACT)   # cut
part = p.part
```

## Primitives

```
Box(length, width, height)
Cylinder(radius, height)
Sphere(radius)
Cone(bottom_radius, top_radius, height)
Torus(major_radius, minor_radius)
```

## Booleans

Algebra: `a + b` union, `a - b` cut, `a & b` intersect.
Inside BuildPart: `mode=Mode.ADD` (default), `Mode.SUBTRACT`,
`Mode.INTERSECT`, `Mode.REPLACE`.

## Positioning

`align=` shifts a primitive inside its own footprint — corner-anchored vs
centred:

```python
from build123d import *
corner = Box(10, 5, 3, align=(Align.MIN, Align.MIN, Align.MIN))        # spans 0..10 x 0..5 x 0..3
centre = Box(10, 5, 3, align=(Align.CENTER, Align.CENTER, Align.MIN))  # centred XY, bottom at z=0
part = corner + centre.move(Location((5, 0, 0)))
```

Move/rotate takes ONE tuple (never `.translate(x, y, z)`).
`Pos(...) * shape` = algebra placement:

```python
from build123d import *
moved = Box(10, 5, 3).move(Location((5, 0, 0)))
rotated = Box(10, 5, 3).move(Location((5, 0, 0), (0, 0, 45)))  # pos + rot
part = moved + Pos(-2, 0, 0) * rotated
```

## Sketch to solid — the canonical recipe for drawing outlines

```python
from build123d import *
pts = [(0, 0), (40, 0), (40, 10), (0, 10)]
with BuildPart() as p:
    with BuildSketch() as sk:
        with BuildLine():
            Polyline(pts, close=True)
        make_face()                  # NO arguments; only inside BuildSketch
    extrude(sk.sketch, amount=2.5)
part = p.part
```

Revolve — the profile must sit OFFSET from the axis, never cross it:

```python
from build123d import *
with BuildPart() as p:
    with BuildSketch(Plane.XZ) as sk:
        with Locations((12, 0)):     # offset the profile from Axis.Z
            Rectangle(4, 8)
    revolve(axis=Axis.Z)             # full 360 degrees
part = p.part
```

## Holes — `Hole` takes ONLY `radius=` and `depth=`

Position comes from the enclosing `Locations` context, NEVER positional args
(`Hole(x, y, t, ...)` is not an API).

```python
from build123d import *
with BuildPart() as p:
    Box(40, 20, 5, align=(Align.MIN, Align.MIN, Align.MIN))
    with Locations((10, 5, 0), (30, 15, 0)):   # hole centres
        Hole(radius=2, depth=5)
part = p.part
```

Regular patterns — never hand-write loops:

```python
from build123d import *
with BuildPart() as p:
    Box(40, 40, 5)
    with GridLocations(20, 20, 2, 2):    # x_spacing, y_spacing, nx, ny
        Hole(radius=2, depth=5)
    with PolarLocations(15, 6):          # radius, count
        Hole(radius=1.5, depth=5)
part = p.part
```

## Selectors

```python
from build123d import *
box = Box(20, 10, 5)
top_face = box.faces().sort_by(Axis.Z)[-1]        # highest-Z face
z_edges = box.edges().filter_by(Axis.Z)           # edges parallel to Z
planar = box.faces().filter_by(GeomType.PLANE)    # planar faces only
part = box
```

`fillet`/`chamfer` run INSIDE BuildPart:

```python
from build123d import *
with BuildPart() as p:
    Box(20, 10, 5)
    fillet(p.edges().sort_by(Axis.Z)[-4:], radius=1)
part = p.part
```

## Mode.PRIVATE — helper geometry that never joins the part

```python
from build123d import *
with BuildPart() as p:
    Box(20, 20, 5)
    helper = Cylinder(3, 5, mode=Mode.PRIVATE)   # queryable, not in p.part
part = p.part
```

## Gotchas

- After every boolean the face count must CHANGE. Unchanged = silent no-op:
  the tool missed the solid (centred vs corner anchoring), or the "cut" was
  a primitive in BuildPart without `mode=Mode.SUBTRACT` — primitives ADD by
  default.
- `Box`/`Cylinder`/`Sphere`/`Cone`/`Torus` are centred at the origin unless
  `align=`/`Location`/`Pos` move them.
- `Locations` inside BuildPart shifts the construction origin of the ops in
  its scope; it does NOT move the finished part.
- `bounding_box()` returns a box: `.min.X`/`.max.Z` are properties, `.center`
  is a METHOD — `part.bounding_box().center().X`.
- `make_face()` takes no arguments and only works inside BuildSketch; never
  pass a BuildLine object to it.
- A revolve profile must be offset from the revolution axis and must not
  cross it.
