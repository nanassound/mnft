# Sketch planes and object selection

- Every `BuildSketch` draws on a LOCAL `Plane.XY` regardless of the placement
  you pass it; the placement is applied when the sketch is published. Selectors
  like `vertices().sort_by(Axis.Z)` inside such a sketch sort LOCAL coordinates
  (all Z = 0) and return essentially random elements. Do position-dependent
  selection on the finished 3D object, not inside a placed sketch.
- Nested builders do NOT inherit placement from their parents; each builds in
  its own local `Plane.XY` and applies its own placement on exit. A `BuildLine`
  inside `BuildSketch` should use the default placement unless you understand
  the place-then-reorient sequence.
- Select top-down, not by coordinates: pick the owning face first, then its
  edges, e.g. `part.faces().sort_by(Axis.Z)[-1].edges().filter_by(GeomType.CIRCLE)`
  before a chamfer/fillet. Hardcoded coordinates break the moment the part
  changes size.
- Avoid self-intersecting geometry (even a single shared vertex — e.g. a helix
  touching itself after one revolution): such topology is invalid; split the
  shape into sections combined afterwards.
