<!-- Upstream text: MIT, © AWV Informatik AG (https://github.com/awv-informatik/smlibpy). -->
<!-- Adapted for mnft; derived from recipes/modeling.md in the smlibpy skill package -->

# smlibpy modeling patterns

## Order of operations

1. **Main body** — a primitive, or a sketch extruded or revolved.
2. **Additions** (bosses, ribs) — fuse them with `+`.
3. **Subtractions** (pockets, holes, slots) — cut them with `-`.
4. **Fillets and chamfers** — last, on edges selected by geometry. Fillet before shelling when the walls should be rounded too.

Features that depend on faces (`.on(face)`) come after the face exists in its final form.

---

## Plate + holes (GridLocations)

Build the plate, round the vertical edges, then subtract a grid of through-holes.
The base sits on Z=0, so a hole tool centred at the origin only cuts the lower half
(a blind hole with a skin on top). Reposition it to mid-height,
`Cylinder(r, t + 4).moved(Pos(0, 0, t / 2))`, so it starts below Z=0 and ends above
the top face. Check the volume: a through hole of radius r removes π·r²·t.

---

## Boss / rib

Build the addition as a separate part, position it, then fuse:

```
base = Box(60, 40, 8, align=(Align.CENTER, Align.CENTER, Align.MIN))
boss = Cylinder(10, 12, align=(Align.CENTER, Align.CENTER, Align.MIN)).translate(0, 0, 8)
part = base + boss
```

For multiple bosses use `PolarLocations(r, n) * Cylinder(...)` or `GridLocations` and fuse the resulting list.

---

## Revolved parts (bushing, flange, nozzle)

Draw the half-section with `Profile`, starting and ending on the axis of revolution.
Use `.fillet(r)` inside the profile to round corners before revolving (cheaper than filleting the solid).
A profile that crosses the axis raises `ModelingError`.

**Always revolve about Z** (mnft is Z-up, base on Z=0): draw the half profile in XY with
x = radius and y = height, then `profile.on(Plane.XZ).revolve(Z)`. Revolving about Y or
with no axis gives a sideways Y-axis part that is also detached from anything built along Z.

---

## Sweeps along helices

Use `Helix(pitch, height, radius)` as the path. `sweep` puts the profile's centre at
the START of the path; a profile cannot be offset from its path, so
`profile.moved(Pos(r, 0, 0))` does nothing. Move the PATH instead: for a tube of
radius `t` whose crest should reach `R`, set the helix radius to `R − t`.
For thread ridges: keep the threaded length ≤ 8 mm at pitch 0.5 (16 turns) — beyond about
16 turns the fuse silently returns the bare shank (a smooth rod, `ok` and no warning).
`assert` that the bbox across the threads reads ≈ the major diameter (M3 → 3.0, not 2.4)
before fusing a head on, and shorten the thread (and say so) if it does not. For a longer
screw use an 8 mm thread plus a plain shank. Never fillet a swept-thread solid.

---

## Shell pattern

`part.shell(thickness, openings=[faces])` hollows a closed solid.
Select opening faces by geometry (`part.faces().top()`), never by index.
Shell before the final fillets when you want rounded inner walls.

---

## Text: engraving and embossing

`Text(string, size)` is a sketch. Place it on a face with `.on(face)`, extrude to depth, then subtract (engrave) or add (emboss). Do text last — letters add many faces that slow down subsequent booleans and fillets.

- `size` is capital height in mm.
- `.on(face)` centres on the face centroid; use a plane + `Pos` or `align=` for exact placement.
- On vertical faces the letters stand upright automatically.

---

## DXF outlines

`import_dxf("outline.dxf")` imports closed loops as a sketch ready to extrude.
Filter layers with `layers=["CUT"]` to exclude construction lines and lettering.
