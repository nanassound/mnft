# BROWSER_SPIKE — mnft in the browser

Branch: `spike/browser-kernel`. Two independently-verifiable spikes that
together sketch a 100%-local nanas.build: **geometry in the browser**
(replicad/OCCT wasm) and **the OTP core in the browser** (Popcorn 1.0).

| Spike | What runs in the browser | Verified |
| ----- | ------------------------ | -------- |
| `cad_worker_web/` | LLM-emitted **replicad dialect** executed in a sandboxed Web Worker against OCCT 8.0.1 wasm (7.3 MB gzip); binary STL + STEP + viewer mesh exported client-side; 30 s watchdog kills runaway models | Node suite 8/8 (same kernel) + live Chromium run: 44-tri hex pen holder, 37.6 cm³, 245 ms kernel time, STL/STEP downloads offered |
| `popcorn_demo/` | **Unmodified Elixir** supervision tree (GenServer-owned ETS journal + DOM-rendering Task) on the real BEAM-in-WASM (Popcorn 1.0, ~730 KB brotli, OTP 29) | Live Chromium run: "BEAM is alive in your browser", ETS journal boot-counted |

## Why this matters for nanas.build

- Zero server geometry CPU per turn → credits margin improves directly.
- BYOK keys stay in the browser; the LLM call is the only network need.
- The "self-hoster" audience gets a tool that runs on *their* machine —
  the repository becomes the product demo.
- Server `cad_worker` stays for CLI and the guaranteed-kernel fulfilment
  path; dialect identity is just an engine choice in `mnft_cad`.

## Next steps if this graduates from spike

1. `mnft_cad`: add the `replicad` engine/dialect next to `build123d`
   (engine contract already pluggable), teach the quickref the JS idioms
   (see `cad_worker_web/README.md` gotchas — destructive `translate()`,
   centre-origin sketches, apothem→circumradius).
2. Wire `cad_worker_web` worker into `mnft_cad_web`'s LiveView as the
   local engine, with the server worker as fallback.
3. Port `mnft_cad`'s journal behind a storage behaviour with an
   in-memory/OPFS implementation, then boot it under Popcorn (start from
   `popcorn_demo/`).
4. Ops: COOP/COEP headers on the host (vite preview/popcorn set their own;
   your reverse proxy must too) and a self-hosted, integrity-pinned wasm.

Both spikes are intentionally small; neither touches existing packages.
