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
Through-hole tools should be taller than the plate so no thin skin remains.

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

---

## Sweeps along helices

Use `Helix(pitch, height, radius)` as the path. Place the profile at the helix radius before sweeping.
For thread ridges: keep threaded length ≤ 20 mm; never fillet a swept-thread solid.

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
