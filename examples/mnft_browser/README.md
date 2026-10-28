# mnft_browser

The whole mnft core — the real `mnft_cad`, unmodified — compiled to
WebAssembly and booted in the browser on
[Popcorn](https://hex.pm/packages/popcorn) 1.0 (the BEAM-in-WASM toolchain).
Geometry runs client-side too: [`core/cad_worker_web`](../../core/cad_worker_web)'s
replicad dialect worker (the OCCT 8 kernel compiled to WASM) executes in a
Web Worker, and the page renders with three.js. No server, no backend, no
filesystem.

## Run

Requirements: Elixir 1.19+, Node.js/npm for the worker build.

```bash
cd ../../core/cad_worker_web && npm install   # once: worker build deps
cd ../../examples/mnft_browser
mix deps.get
mix dev        # http://localhost:4000 — dev server
mix cook       # packaged build in public/out (MIX_ENV=prod mix cook for prod)
```

`mix dev`/`mix cook` first run `mix host.assets`, which builds the
replicad worker into `public/kernel/` and copies three.js into
`public/vendor/three/`.

## Bring your own key

The LLM key is typed into the page's settings panel and configured at
runtime (an `llm_config` call on the kernel bridge); it travels browser →
provider only and is never read from disk. Without a key the app runs a
scripted fake turn (`Mnft.Cad.LLMFake`) that builds a 40 mm hexagonal pen
holder — the port of `cad_worker`'s sample part to the replicad dialect.

## Layout

- `lib/mnft_browser/kernel.ex` — the `:mnft_kernel` GenServer; the page
  calls `popcorn.tryCall("mnft_kernel", ["turn", …] | ["llm_config", …])`.
- `lib/mnft_browser/engines/replicad.ex` — `Mnft.Cad.Engine` for the
  browser: dispatches JS to the page-side worker; STL/STEP bytes never
  enter the BEAM (artifacts stay page-side behind `mem://` handles).
- `lib/mix/tasks/host_assets.ex` — builds the worker and vendor assets
  into `public/` (see Run).
- `config/config.exs` — the core wired for WASM: ETS store with the
  journal off (no filesystem), the replicad engine, the fake LLM, events
  bridged to the page.
- `public/app.js` — the page: BEAM bridge, settings panel, three.js
  viewer. `window.__popcorn` in the console reaches the kernel bridge
  directly.

The embedding guide for the core is
[`mnft_cad/README.md`](../../core/mnft_cad/README.md) (its engines are
build123d and OpenSCAD). The replicad engine this app runs — dialect
quickref, parity with the Python worker, security posture — is documented
in [`cad_worker_web/README.md`](../../core/cad_worker_web/README.md).
