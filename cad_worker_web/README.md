# cad_worker_web

The browser twin of `cad_worker`: a guarded dialect runner that executes
LLM-generated CAD code **entirely in the browser**, against the real OCCT 8
kernel compiled to WebAssembly (`replicad` + `replicad-opencascadejs`).

Same contract as the Python worker's dialects:

| cad_worker (Python/build123d)      | cad_worker_web (JS/replicad)                     |
| ---------------------------------- | ------------------------------------------------ |
| AST import allowlist               | acorn-walk static checks (`replicad` only)       |
| `exec(src, ns)` harness            | `new Function` harness with capture-tail         |
| math pre-bindings (`pi`, `sin`, …) | same bare names bound into the namespace         |
| shape picked: part/result/assembly/obj | identical convention, arrays → compound      |
| exports STL + STEP + GLB           | exports binary STL + STEP + viewer mesh          |
| rlimits + wall clock               | Web Worker sandbox + 30 s watchdog (kill+respawn)|

## Run

```bash
npm install
npm test        # Node smoke tests — same kernel, same dialect, no browser
npm run dev     # demo page on http://localhost:4210
```

The Node tests prove the full pipeline (kernel load → dialect run → volume
check against first principles → binary STL + STEP export) without a browser;
the browser worker uses the very same `dialects/replicad.js` module.

## Dialect quickref (what the LLM must be taught)

```js
// imports: only `replicad` (its API is bound as bare names anyway)
import { sketchPolysides } from "replicad";

const acrossFlats = 40.0, wall = 3.0, height = 90.0;

// sketch (2D) → extrude → boolean; sketchPolysides radius = CIRCUMRADIUS
const circumRadius = (across) => across / 2 / Math.cos(pi / 6);
const outer = sketchPolysides(circumRadius(acrossFlats), 6).extrude(height);
const inner = sketchPolysides(circumRadius(acrossFlats - 2 * wall), 6).extrude(height);
const part = outer.cut(inner.translate(0, 0, wall));
```

Gotchas discovered while porting the sample part (these belong in the
dialect quickref taught to the LLM, like build123d's own idioms):

- **`shape.translate()` is destructive** in replicad 1.2 — the source shape
  is freed. Place independently-built shapes; never reuse a translated one.
- `sketchRectangle`/`sketchCircle` are **centre-origin**.
- Bare trig names (`sin`, `cos`, `pi`, `radians`, …) are dialect
  pre-bindings, not JS globals.
- BREP shapes have no `.volume()` — the dialect measures via
  `measureShapeVolumeProperties`; a *filled* cut removes
  `A_out·h − A_in·(h−shift)` of material, not `(A_out−A_in)·(h−shift)`.

## Security posture (spike-honest)

- The worker is the sandbox: no DOM, no fetch of user code, dialect static
  checks add a second layer (import allowlist, no `require`/`eval`/`import()`,
  no `globalThis`/`process` reach).
- The watchdog kills a runaway synchronous loop by terminating the worker
  and respawning a fresh kernel (kernel is HTTP-cached, so respawn is cheap).
- NOT yet covered (parity work, mirroring cad_worker): memory limits
  (Workers lack rlimits), per-turn output quotas, code size caps.

## Why this shape

mnft's promise is "an STL, a STEP, and a 3D preview" — all three now happen
client-side with zero server geometry CPU. The server `cad_worker` stays for
CLI use and as the guaranteed-kernel fallback; dialect identity
(`replicad` vs `build123d`) is just an engine choice in `mnft_cad`.

Kernel provenance: `replicad-opencascadejs` 1.1.0 (OCCT 8.0.1 wasm via the
libcascade toolchain). Pin it, self-host the wasm, integrity-check it.
