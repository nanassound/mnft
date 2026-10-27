# popcorn_demo

Spike: `mnft_cad`'s shape — a pure Elixir/OTP core with a supervision tree
and ETS-backed journal — booted **inside the browser** on Popcorn 1.0
(OTP/BEAM compiled to WebAssembly).

Verified live: BEAM boots in the tab (`otp_release = 29`, ERTS 17.0.6,
Elixir 1.20.4), `PopcornDemo.Supervisor` runs `one_for_one` with a
GenServer-owned ETS journal + a Task that renders the page **from Elixir**
via `Popcorn.JS.run!/1`. Each VM boot re-journals its boot count into ETS.

## Run

```bash
cd popcorn_demo
# Popcorn 1.0 needs its pinned toolchain, NOT the repo-wide 1.18.4-otp-27:
export PATH="$HOME/.asdf/shims:$PATH" ASDF_DATA_DIR="$HOME/.asdf" \
       ASDF_ELIXIR_VERSION=1.20.4-otp-29 ASDF_ERLANG_VERSION=29.0.5
mix deps.get && mix compile
mix popcorn.dev        # serves on :4000, falls back to a random port if taken
```

`mix popcorn.dev` packages the app's `.beam` files into `public/out/`
(`beam.wasm` + `beam.emu.mjs` + stdlib `.tar.br`, all precompressed) and
serves the page; the browser downloads the VM (~730 KB brotli) and boots
your supervision tree.

## What the spike proves / what it doesn't

Proven:
- Unmodified Elixir (no popcorn-specific code except the `Popcorn.JS` calls
  the docs prescribe) boots under a supervision tree in the browser.
- ETS works — with one sharp edge worth knowing (below).
- DOM access from Elixir via `Popcorn.JS.run!` (the atelier/mnft UI bridge).

Not yet (the real port):
- `mnft_cad`'s fsynced file journal → needs an OPFS/in-memory storage
  adapter (pluggable storage makes this a module swap, not a rewrite).
- LLM HTTP calls → `Popcorn.Fetch` (Req adapter over `fetch()`), BYOK keys
  from the browser side.
- cad_worker: stays server-side; the browser geometry path is
  `cad_worker_web` (replicad dialect worker) — the two meet in the UI.

## Sharp edge found (and fixed here)

An ETS table created inside a `{Task, fn -> :ets.new(...) end}` child dies
with the Task (ownership), so the next insert crashes the boot banner —
and Popcorn surfaces an unhandled boot crash as a terse **"VM exited"**.
Tables need a long-lived owner: `PopcornDemo.Journal` is a GenServer whose
`init/1` creates the table. This is exactly the kind of lifetime rule the
real `mnft_cad` port has to respect (its journal is already a GenServer
upstream, so the port is natural).

## Toolchain note

`mix.exs` requires `~> 1.20` Elixir and Popcorn 1.0 pins **OTP 29** — the
repo-wide `.tool-versions` (1.18.4-otp-27) is too old for this directory.
Overrides above use the asdf-installed 1.20.4-otp-29 / 29.0.5; Popcorn's
mise.toml pins erlang 29.0.6 and 29.0.5 booted the shipped VM fine.
