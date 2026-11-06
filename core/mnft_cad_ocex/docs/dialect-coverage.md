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
| named solids | box, cylinder, sphere, prism (sugar: polygon+extrude) | ✅ |
| profiles | polygon | ✅ seed — polyline+arc+spline+slot missing |
| sweeps | extrude | ✅ — revolve, sweep, loft missing (OCEx has all three) |
| booleans | union, cut, intersect | ✅ |
| transforms | translate, rotate | ✅ — mirror, scale missing (OCEx has both) |
| finishing | fillet_all | 🟡 all-edges only — selected-edge fillet/chamfer needs a selector mini-language |
| patterns | — | ❌ linear/circular patterns, mirror-array (biggest multiplier: bolt circles) |
| domain | — | ❌ thread (decomp: triangle profile + helix sweep), gear, text (OCEx has font faces) |

## Corpus audit v1 (build123d ~ Operations/Objects, CadQuery, OpenSCAD)

Legend: ✅ expressible today · 🟡 expressible via workaround · ❌ gap (no faithful expression) · ⛔ out of dialect scope by design

| reference API | class | ocex status | note |
|---|---|---|---|
| Box / Cube | named solid | ✅ box | |
| Cylinder | named solid | ✅ cylinder | |
| Sphere | named solid | ✅ sphere | |
| Cone | named solid | ❌ | trivial OCCT binding; add with revolve batch |
| Torus | named solid | ❌ | same |
| Polygon / RegularPolygon | profile | 🟡 polygon covers regular n-gons; arbitrary polygons → polyline (✅) | |
| Rectangle / Circle sketch | profile | ❌ | box covers rects; circle-as-face missing |
| Polyline + close | profile | ✅ polyline | L/T/I brackets, keyways, gaskets |
| Spline / Bézier | profile | ❌ | organic 2D outlines (OCEx has spline) |
| Slot / Tee / Trapezoid sketches | profile | 🟡 sugar over polyline | thin wrappers; add on demand |
| extrude | sweep | ✅ | |
| revolve | sweep | ❌ | OCEx.revolve exists (face, origin, axis, degrees) |
| sweep along path | sweep | ❌ | OCEx.sweep exists; unlocks helix→thread |
| loft | sweep | ❌ | OCEx.loft exists |
| offset / shell | finishing | ❌ | shell = hollow enclosure; OCEx.shell exists (openings, t) |
| fillet/chamfer all edges | finishing | ✅ fillet_all | chamfer_all missing (chamfer twin, trivial) |
| fillet/chamfer selected edges | finishing | ❌ | needs edge selector mini-language (by face, by axis) |
| mirror | transform | ❌ | OCEx.mirror exists (origin, normal) |
| linear/circular pattern | pattern | ❌ | highest-leverage gap: bolt circles, vent arrays |
| scale | transform | ❌ | OCEx.scale exists |
| text | domain | ❌ | OCEx has font-backed faces (FreeType/HarfBuzz) |
| thread | domain | 🟡 | expressible after sweep: triangle profile + helix wire |
| gear | domain | ❌ | compound op, later |
| boolean fuse/cut/common | boolean | ✅ | |
| sections/sections of solid | inspection | ⛔ | belongs to inspection/harness layer, not the modelling dialect |
| export formats | boundary | ✅ engine exports STL/STEP | GLB preview best-effort |
| assembly/joints | boundary | ⛔ | mnft models single parts today; assembly is a separate dialect later |

## Priority order (value ÷ effort)

1. `polyline` + `close` + `planar face` — unlocks L/T/I brackets, keyways, gaskets
2. `pattern_circular` / `pattern_linear` — bolt circles, vent arrays (kills 25-op hand loops)
3. `revolve` + `loft` — knobs, funnels, vases, tapered parts
4. `mirror` + `scale` — two one-liners (OCEx calls exist)
5. `chamfer_all`, `shell` — finishing parity with OpenSCAD-level expectations
6. `sweep` along polyline/helix — handles, rails, threads
7. Selected-edge fillet/chamfer — needs the selector language, design first
8. `circle` as face, text faces — small, standalone

Rule: every new verb lands with its prompt row, static validation, interpreter
op, and tests asserted against analytic geometry — then gets a line in the
corpus table above. The audit shrinks; coverage only goes up.
