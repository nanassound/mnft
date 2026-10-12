# Technical drawings and datasheets

- If the message contains a "[Vector outline extracted ...]" block, its
  vertices ARE the section outline, read from the PDF's own vector data.
  Scale the vertex list with ONE factor: pair the outline's LONGEST bbox
  side with the LARGEST dimension callout listed for it (the overall
  dimension is the biggest number, never a sum of segment callouts), then
  apply that scale to both axes. Build the profile from exactly those
  points. Do NOT re-trace the drawing from the image; the image is only
  context.
- Vector points → solid, canonical form (build123d 0.13). `make_face()` takes
  NO arguments and only works inside BuildSketch; translation takes ONE tuple:

      with BuildSketch() as sk:
          with BuildLine():
              Polyline(pts, close=True)  # pts already in mm
          make_face()
      part = extrude(sk.sketch, amount=length)

  The extracted outline is ONE closed boundary that ALREADY includes every
  section feature (bulges, keyhole circles, notches) — never add sketch
  primitives (Circle, Rectangle) to the cross-section. Features that repeat
  along the LENGTH (e.g. M3 tapped holes) are 3D: subtract cylinders AFTER
  extrusion, e.g. `part -= Pos(x, 0, 0) * Cylinder(r, depth)`.
  Never pass a BuildLine object to make_face; never call
  `.translate(x, y, z)` — use `.translate((dx, dy, dz))` or `Pos(...)`.
- There is NO `Hole(...)` helper and no arithmetic on `bounding_box()` (it is
  a method: `part.bounding_box()` returns a box, do not subtract it). If a
  feature needs an API you are not certain of, build it from only these
  verified pieces: `Box`, `Cylinder`, `Cone`, `Polyline`, `Circle`,
  `Pos`, `extrude`, and boolean `+`/`-`.
- Plates from dimensioned drawings: build the plate AT THE DRAWING'S DATUM so
  position callouts apply directly — `Box(w, h, t, align=(Align.MIN,
  Align.MIN, Align.MIN))` spans 0..w × 0..h × 0..t; hole (x, y) callouts are
  distances from the sheet's 0/0 marks, NOT offsets from the part center.
  Through cuts must OVERSHOOT both faces (never flush): `Pos(x, y, 0) *
  Cylinder(r, t + 2, align=(Align.CENTER, Align.CENTER, Align.MIN))`.
- Concentric circles in a view + an angle callout in the section view
  (e.g. 90°) = countersunk screw hole: through hole r from the inner circle,
  countersink cone from the outer circle's R at the face, depth = R − r for
  90° included:
      part -= Pos(x, y, 0) * Cylinder(r, t + 2,
                 align=(Align.CENTER, Align.CENTER, Align.MIN))
      part -= Pos(x, y, t) * Cone(R, r, R - r,
                 align=(Align.CENTER, Align.CENTER, Align.MAX))
- A datasheet drawing usually shows a CROSS-SECTION profile plus a length. The
  part is: draw the 2D closed profile, then extrude it along the given length.
- FIRST, before the code block, output a "Profile walk:" list: each straight
  edge of the section outline in order (clockwise), as (x, y) -> (x, y), with
  the datasheet dimension that justifies each edge. Use the labeled callout
  values from the drawing, not guesses.
- Build coordinates from the drawing's own datum. For an unlabeled callout you
  cannot place, state the assumption explicitly.
- Do NOT invent edges that are not in the drawing. If you cannot trace the
  section outline, say so and emit no code block.
- Dimension callouts nearest an edge measure THAT edge; extension lines show
  which two points a dimension spans. Read them off the drawing, don't
  redistribute bare numbers from the text dump.
