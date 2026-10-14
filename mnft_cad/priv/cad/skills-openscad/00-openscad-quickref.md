# OpenSCAD quickref

## Do not write Python

Models default to `from build123d import *` out of habit. Here there is no
Python at all: `import` of any kind is rejected before the code runs, and the
turn wastes a repair round trip. The output is OpenSCAD script — module calls
(`cube`, `cylinder`, `difference()`) and `part = ...` assignments only.

## Language map (build123d habit → OpenSCAD)

| build123d habit | OpenSCAD |
|---|---|
| `from build123d import *` | (delete — no imports) |
| `Cylinder(r, h)` centred | `cylinder(h = h, r = r, center = true)` or `$fn` |
| `Box(l, w, h)` centred | `cube([l, w, h], center = true)` |
| `Pos(x,y,z) * shape` | `translate([x, y]) shape();` |
| `Rot(...) * shape` | `rotate([x, y, z]) shape();` |
| `extrude(sketch, amount)` | `linear_extrude(height) shape2d();` |
| `revolve(profile, axis=Z)` | `rotate_extrude() polygon(pts);` (profile x ≥ 0) |
| `part - tool` | `difference() { part(); tool(); }` |
| `part + tool` | `union() { a(); b(); }` or juxtaposition |
| `part & tool` | `intersection() { a(); b(); }` |
| fillet/chamfer edges | no direct equivalent — `offset(r)` on 2D, `hull()`, or revolve a chamfered profile |
| `Helix` + `sweep` | `linear_extrude(height, twist = degrees, slices = n)` |

## Non-negotiables

- The part is the file's LAST top-level geometry statements (module calls or a
  trailing `union()`/`difference()` block). NEVER write `part = union() {...}` —
  geometry cannot be assigned to a variable; that is a parser error.
- Model centred on X/Y, base on Z=0.
- No `import(`/`include`/`use`/`surface(` — rejected statically.
- `$fn <= 96`. No nested `minkowski()`. 60 s render budget.
- Through holes: the cutting cylinder starts below z=0 and ends above the top
  (overshoot 1 mm each side) — coincident faces leave a skin.
- Radius discipline: `cylinder(r=...)` takes a radius; halve diameters and
  across-flats widths, and say so in the reply.
