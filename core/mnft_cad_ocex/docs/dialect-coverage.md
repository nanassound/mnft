# ocex dialect coverage — living audit

Method: a closed verb list can never enumerate "what users prompt". Coverage
is measured three ways instead:

1. **Corpus audit** (this file) — the public APIs of build123d / CadQuery /
   OpenSCAD are a decade of accumulated "what users ask for". Classify every
   reference function into a dialect grammar slot; anything unclassifiable is
   a named gap with a reference implementation sitting in Python.
2. **Coverage fuzzing** — synthetic prompts from a parts taxonomy run through
   the real prompt + static check; expressible % is a tracked metric.
3. **Production telemetry** — every repair-loop rejection of an invented verb
   on nanas.build ("unknown op: chamfer") is a gap report with demand count.
   Review the histogram weekly.

Grammar rule of thumb: a verb earns its place only if it is NOT expressible
as a short composition of existing ops. Named solids (`box`, `prism`) are
sugar over profiles + sweeps, never new machinery.

## Grammar layers & status

| layer | dialect ops | status |
|---|---|---|
| named solids | box, cylinder, sphere, prism (sugar: polygon+extrude), cone, torus | ✅ |
| profiles | polygon, polyline, circle | ✅ seed — arc+spline+slot missing |
| sweeps | extrude, revolve, loft, sweep, helix | ✅ |
| booleans | union, cut, intersect | ✅ |
| transforms | translate, rotate, mirror, scale | ✅ mirror fuses the reflection in; scale is origin-anchored |
| finishing | fillet_all, chamfer_all, fillet, chamfer, shell | ✅ selectors by face plane |
| patterns | pattern_linear, pattern_circular | ✅ fuse copies through the original (Σcount ≤ 1000) |
| domain | text | 🟡 thread machinery complete (golden), gear ❌ compound op later |

## Corpus audit v1 (build123d ~ Operations/Objects, CadQuery, OpenSCAD)

Legend: ✅ expressible today · 🟡 expressible via workaround · ❌ gap (no faithful expression) · ⛔ out of dialect scope by design

| reference API | class | ocex status | note |
|---|---|---|---|
| Box / Cube | named solid | ✅ box | |
| Cylinder | named solid | ✅ cylinder | |
| Sphere | named solid | ✅ sphere | |
| Cone | named solid | ✅ cone | frustum via r2; r2=0 gives an apex |
| Torus | named solid | ✅ torus | about z, centred at `at` |
| Polygon / RegularPolygon | profile | 🟡 polygon covers regular n-gons; arbitrary polygons → polyline (✅) | |
| Rectangle / Circle sketch | profile | ✅ circle | box covers rects; circle face in XY (a face, not a solid) |
| Polyline + close | profile | ✅ polyline | L/T/I brackets, keyways, gaskets |
| Spline / Bézier | profile | ❌ | organic 2D outlines: no dialect op (OCEx `spline` is used only inside `helix`) |
| Slot / Tee / Trapezoid sketches | profile | 🟡 sugar over polyline | thin wrappers; add on demand |
| extrude | sweep | ✅ | |
| revolve | sweep | ✅ revolve | profile plane must contain the axis (kernel accepts a perpendicular profile with zero volume) |
| sweep along path | sweep | ✅ sweep / helix | profile at the path start, ⊥ to its tangent. `helix` is a spline APPROXIMATION through `round(turns*48)+1` samples, led in by a 0.5 µm straight stub on the exact analytic tangent (the kernel's 1e-7 alignment check); tests hold it to 1% of the analytic arc length and 5% of the swept thread volume |
| loft | sweep | ✅ loft | ruled; sections in push order |
| offset / shell | finishing | ✅ shell | hollows the body; `open` selector (required ≥1) removes a lid/wall (kernel: no closed hollow; offset stays ❌) |
| fillet/chamfer all edges | finishing | ✅ fillet_all / chamfer_all | |
| fillet/chamfer selected edges | finishing | ✅ fillet / chamfer | `on` face selector; edges matched by native identity against the selected faces |
| mirror | transform | ✅ mirror | fuses the reflection into the shape (mirror-completes) |
| linear/circular pattern | pattern | ✅ pattern_linear / pattern_circular | fuse copies through the original; a patterned bore cuts all instances |
| scale | transform | ✅ scale | uniform, about the world origin |
| text | domain | ✅ text | bundled Graduate font (OFL license ships with the pack); size is em, baseline at origin/`at` |
| thread | domain | 🟡 machinery complete | triangle profile + helix + sweep verified (golden); teeth need tuning per thread form |
| gear | domain | ❌ | compound op, later |
| boolean fuse/cut/common | boolean | ✅ | |
| sections/sections of solid | inspection | ⛔ | belongs to inspection/harness layer, not the modelling dialect |
| export formats | boundary | ✅ engine exports STL/STEP | GLB preview best-effort |
| assembly/joints | boundary | ⛔ | mnft models single parts today; assembly is a separate dialect later |

## Status after the 8-list sweep (Nov 2026)

All eight priority lists from the first audit are landed: polyline, patterns
(+ compound-aware booleans), revolve/loft/cone/torus, mirror/scale,
chamfer_all/shell (selector engine), sweep/helix, selected-edge
fillet/chamfer, circle/text faces (Graduate font vendored). Every verb came
with its prompt row, static validation, interpreter op, and tests asserted
against analytic geometry; shell and the sweep goldens use kernel-measured
values where OCCT geometry is not a naive analytic solid (dated comments).

## Remaining gaps (value ÷ effort)

1. Arc / spline 2D outlines — `polyline` covers straight edges only; OCEx has
   an `arc` binding the dialect does not expose, and `spline` is used only
   inside `helix`. Unlocks organic profiles and filleted 2D
   sketches. Consider a `profile` op that chains line/arc/spline segments.
2. Slot / Tee / Trapezoid sugar — thin wrappers over `polyline`; add on
   telemetry demand, not speculatively.
3. Gear — compound op (involute or simplified trapezoid teeth via
   polyline+extrude); needs a tooth-profile generator, later batch.
4. offset / thicken — `shell` covers hollowing with a required opening; pure
   outward offset (grow a 2D profile, thicken a surface) has no op and no
   faithful composition.
5. Thread sugar — machinery verified (profile + helix + sweep golden); a
   dedicated `thread` op would hide the tangent-stub and profile-placement
   gotchas from the prompt entirely.

Rule unchanged: every new verb lands with its prompt row, static validation,
interpreter op, and tests asserted against analytic geometry — then gets a
line in the corpus table above. The audit shrinks; coverage only goes up.
