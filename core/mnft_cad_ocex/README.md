# mnft_cad_ocex

Native engine pack for [`mnft_cad`](../mnft_cad): executes the **ocex** JSON
construction dialect in the BEAM via [OCEx](https://hex.pm/packages/ocex)
native bindings to Open CASCADE Technology 7.9.3. Exact B-rep STEP + STL
export (helix sweeps are a tolerance-backed spline approximation),
no Python, no external binary — the compiled NIF is the runtime.

The core stays pure Elixir; only consumers that opt into this pack compile
OCEx. Wire it with:

```elixir
# mix.exs
{:mnft_cad_ocex, path: "core/mnft_cad_ocex"}

# config
config :mnft_cad, :cad, engine: MnftOcex.Engine
```

## The ocex dialect

A straight-line JSON stack program (the LLM writes it; `MnftOcex.Dialect`
validates before any native call; `MnftOcex.Interpreter` executes):

```json
{"ops": [
  {"op": "box", "size": [60, 40, 5]},
  {"op": "cylinder", "r": 4, "h": 20, "at": [30, 20, -5]},
  {"op": "cut"},
  {"op": "fillet_all", "r": 1}
]}
```

| op | params | effect |
|---|---|---|
| `box` | `size:[x,y,z]`, `at?` | corner-anchored solid |
| `cylinder` | `r`, `h`, `at?` | base-centred, extends +z |
| `sphere` | `r`, `at?` | centred solid |
| `cone` | `r1`, `r2`, `h`, `at?` | cone/frustum, radius r1 at z=0 → r2 at z=h (`r2:0` = apex) |
| `torus` | `R`, `r`, `at?` | ring torus about z, centred at `at` (`r < R`) |
| `translate` | `delta:[dx,dy,dz]` | moves the top shape |
| `union` / `cut` / `intersect` | — | consume the top two (top = tool) |
| `fillet_all` | `r` | rounds every edge of the top shape |
| `chamfer_all` | `d` | bevels every edge of the top shape |
| `fillet` | `r`, `on[selector]` | rounds only the edges of the selected faces |
| `chamfer` | `d`, `on[selector]` | bevels only the edges of the selected faces |
| `shell` | `t`, `open[selector…]` | hollows the top shape; `open` (required ≥1) selectors name the removed faces |
| `polygon` | `n`, `r`, `rot?`, `at?` | planar n-gon **face** in XY (not a solid) |
| `polyline` | `pts:[[x,y,z]…]`, `close?=true`, `at?` | planar face through the points (`close:false` → open wire, sweep path) |
| `circle` | `r`, `at?` | planar circular **face** in XY (not a solid; bores use `cylinder`) |
| `text` | `s ≤ 256`, `size`, `at?` | planar text face in the bundled Graduate font (size = em, baseline at origin/`at`) |
| `extrude` | `h`, `dir?` | pops a face, pushes a solid (out-of-plane only) |
| `revolve` | `axis`, `at?`, `degrees?` | pops a face, pushes the swept solid (profile plane must contain the axis) |
| `loft` | `sections` | pops N faces (first pushed = first section), pushes a ruled solid |
| `sweep` | — | pops path (top) + profile face, pushes the swept solid (profile at path start, ⊥ tangent) |
| `helix` | `r`, `pitch`, `turns ≤ 25`, `at?` | pushes an open helix **wire** (sweep path), CCW about +z from [r,0,0]+at |
| `rotate` | `axis`, `degrees` | spins the top shape about a world axis |
| `mirror` | `normal:[x,y,z]`, `at?` | top fused with its reflection across the plane (mirror-completes) |
| `scale` | `factor` | uniform scale about the world origin |
| `pattern_linear` | `count`, `delta:[dx,dy,dz]` | top fused with count−1 translated copies |
| `pattern_circular` | `count`, `axis?`, `at?`, `degrees?` | top fused with count−1 rotated copies (default z axis, 360°) |

Rules: millimetres, ≤200 ops, all dimensions positive and finite, the final
stack must hold exactly one shape. Booleans pop blank-then-tool — push the
blank first. Cuts that miss the part are silent no-ops (in *every* kernel).

## Tests

```sh
mix test                          # unit + engine contract + kernel geometry
mix test --include cross_kernel   # + agreement vs the build123d Python worker
```

The cross-kernel test needs `core/cad_worker/.venv` (build123d). Golden
model: 100×100×10 plate, 5×5 grid of r=3 through-bores, analytic volume
92931.4165 mm³ — verified identical (to all digits) on OCEx and build123d.

## Production notes

- **Isolate the geometry.** OCEx kernel calls are serialised per BEAM node
  and cannot be cancelled; a native fault in OCCT kills the whole VM. Run
  this engine in its own BEAM node/container (the core's
  `Mnft.Cad.ExecLimiter` already caps concurrent builds).
- **Throughput** (measured 5 Nov 2026, this repo's spike):
  ~1.5 ms small op, ~7 ms boolean, ~33 ms per typical model, ~680 ops/s per
  node. RAM ~115 MB idle vs ~391 MB for a build123d worker.
- **STEP export** prints OCCT transfer chatter to stdout (upstream cosmetic).
- The OCCT toolkit must be present at runtime; builds need
  `OpenCASCADE_DIR` or the default `~/.local/occt-7.9.3` source install
  (see `Projects/ocex-spike/README.md` for the full environment recipe).
