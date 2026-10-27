# replicad core skills

Quick reference for the browser replicad dialect (replicad + OpenCASCADE
wasm). The runner is `cad_worker_web`: your ```js block is static-checked,
then executed in a Web Worker with the whole replicad API pre-bound.

## Imports and host access

- Do NOT import anything. Every public replicad name is already bound as a
  bare identifier (`sketchCircle`, `extrude`, `cut`, `measureShapeVolumeProperties`, …).
  If you must, the only allowed import is `import { x } from "replicad"`.
- The static check REJECTS: `import()` of anything else, `export`,
  `require(...)`, `eval(...)`, and any `.member` access on `globalThis`,
  `global`, `window`, `document`, `self`, `process`. No network, no DOM,
  no filesystem: pure geometry only.
- Determinism required: no `Math.random`, no `Date.now`.

## Pre-bound math names (Python-style, NOT on `Math.`)

`pi`, `e`, `tau`, `sin`, `cos`, `tan`, `asin`, `acos`, `atan`, `atan2`,
`sinh`, `cosh`, `tanh`, `sqrt`, `exp`, `log`, `log10`, `floor`, `ceil`,
`trunc`, `hypot`, `radians(deg)`, `degrees(rad)`, `fabs(x)`, `copysign`,
`fmod`, plus the `math` object. `Math.cos(...)` also works — both are
available.

## Shape convention

- Bind the final shape to `part` (fallbacks: `result`, `assembly`, `obj`).
- An array of shapes (`[a, b, c]`) is accepted and becomes one compound.
- Centre the model on X/Y, base on Z=0.

## The gotchas (each one burned us in production)

- **`translate()` is destructive** (replicad 1.2): translating FREES the
  source shape. Never reuse a translated shape; build a fresh one instead.
  `outer.cut(inner.translate(0, 0, wall))` is correct only because `inner`
  is never used again.
- **`sketchRectangle(w, h)` and `sketchCircle(r)` are centre-origin** —
  the centre sits on the sketch origin. To offset, build a translated copy
  (once!) or plan coordinates accordingly.
- **`sketchPolysides(radius, n)` takes the CIRCUMRADIUS.** A hexagon
  specified by across-flats `af` (the apothem) converts as
  `af / 2 / Math.cos(pi / 6)`. Self-check: bbox X extent then reads
  across-corners = `af / cos(30°)`.
- **Volumes**: BREP shapes have no `.volume()`. Use
  `measureShapeVolumeProperties(shape).volume` (returns `undefined` for
  surfaces). The runner already measures and reports volume, bbox and
  triangle count for you.

## Worked example (the sample part, 40 mm hex pen holder)

```js
const acrossFlats = 40.0, wall = 3.0, height = 90.0;

// across-flats (apothem) -> circumradius
const circumRadius = (across) => across / 2 / Math.cos(pi / 6);

const outer = sketchPolysides(circumRadius(acrossFlats), 6).extrude(height);
const inner = sketchPolysides(circumRadius(acrossFlats - 2 * wall), 6).extrude(height);
const part = outer.cut(inner.translate(0, 0, wall));
```

A *filled* pen holder removes `A_out·h − A_in·(h−wall)` of material — the
floor stays — not `(A_out − A_in)·(h−wall)`.
