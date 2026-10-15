# mnft_cad

Open core for chat-to-CAD modelling on the BEAM. Describe a part in plain
language, an LLM writes CAD code, a guarded engine builds it, you get
STL / STEP / GLB plus the editable engine script itself (`model.py` /
`model.scad`) so you can keep iterating in your own tools. The core is pure
Elixir/OTP and embeds in any host
application: it brings the modelling pipeline and its own storage, and the
host brings the web framework, the auth, and any heavier database.

## What's inside

- **Turn pipeline** (`Mnft.Cad.Turn`): LLM → code extraction → static gate →
  guarded execution → exactly one automatic repair attempt → noop-recheck,
  all budget-capped. Runs in a supervised task; one Jido agent per session
  owns the busy gate.
- **Engine behaviour** (`Mnft.Cad.Engine`), selected by config:
  - `Mnft.Cad.Engines.Build123d`: Python worker (`cad_worker/` in the repo)
    over a Port; full fidelity, STEP/STL/GLB, Python-AST static gate.
  - `Mnft.Cad.Engines.OpenScad`: the `openscad` binary over a Port; pure
    Elixir STL measurement + GLB preview, zero Python, ~40 MB install.
    Mesh-only, so **no STEP**: use it for 3D-printing workflows; CAM work
    needs build123d.

  | | build123d | OpenSCAD |
  |---|---|---|
  | STEP (manufacturing) | yes | no |
  | STL | yes | yes |
  | GLB preview | yes | yes |
  | runtime | Python + OCP (~1 GB wheels) | single binary |
  | LLM target | Python (build123d) | OpenSCAD DSL |

- **Storage behaviour** (`Mnft.Cad.Store`): default adapter is
  `Mnft.Cad.Store.Ets`, ETS for reads with an fsynced append-only JSONL
  journal for durability (`data/mnft_cad.jsonl`). One journal line per turn;
  a crash at any point loses at most the in-flight turn; boot replay
  rebuilds ETS; compaction is automatic. Hosts plug in their own adapter
  (the closed SaaS runs Ecto/Postgres behind the same callbacks).
- **LLM client** (`Mnft.Cad.LLM`, via req_llm): any OpenAI-compatible
  endpoint or native driver (Anthropic/Claude, and other req_llm providers)
  by config; BYO key via a resolver, which can be a string,
  `{:system, "VAR"}`, or `{Mod, fun, args}`. Per-turn text/vision model
  routing. Provider, endpoint and models are config only, and the core
  stays vendor-neutral. Error strings are redacted; image bytes never touch
  storage or logs.
- **Events** (`Mnft.Cad.Events`): stage events (`turn_started`, `llm_started`,
  `llm_done`, `exec_started`, `exec_done`, `turn_done`, `turn_failed`)
  delivered to a `{mod, fun, args}` handler, ready to bridge into your own
  PubSub. Plus `[:mnft_cad, :cad, :turn]` telemetry.

## Quick start (library)

```elixir
{:mnft_cad, path: "mnft_cad"}   # or from Hex once published
```

```elixir
# config/config.exs
config :mnft_cad, :cad,
  events: {MyApp.PubSubBridge, :emit, []},
  store: Mnft.Cad.Store.Ets,             # default
  engine: Mnft.Cad.Engines.Build123d,    # or Mnft.Cad.Engines.OpenScad
  models_dir: "data/models",
  data_dir: "data",
  llm: [
    provider: :openai,
    base_url: "https://api.z.ai/api/paas/v4",
    api_key: {:system, "LLM_API_KEY"},
    text_model: "glm-5.3-flash",
    vision_model: "glm-4.6v",
    timeout_s: 600,
    max_tokens: 32_768,
    repair_max_elapsed_s: 240
  ]
```

```elixir
{:ok, session} = Mnft.Cad.create_session(owner_id)
{:ok, :started} = Mnft.Cad.Sessions.request_turn(session, "a 30 mm cube with a 12 mm hole", [], %{})
# progress arrives via your event handler; the finished turn is persisted
```

A complete runnable version of this, with multiple owners, multiple
sessions, turns in flight at once, and an event collector with `await`,
lives in `../mnft_cad_headless` in the repo. Run it offline with
`MNFT_HEADLESS_FAKE=1 mix run -e "MnftCadHeadless.run()"`.

`owner_id` is an opaque string you control (a user id, an anonymous cookie
id, …). The core never authenticates; auth, quotas and billing belong to
the host.

## Python worker (build123d engine)

```bash
cd cad_worker && uv venv --python 3.12 && uv pip install -e . pytest
```

```bash
cd mnft_cad && mix test
```

Config keys: `CAD_WORKER_PYTHON`, `CAD_WORKER_CWD`, `CAD_EXEC_CONCURRENCY`,
`CAD_EXEC_TIMEOUT_S`, `CAD_MODELS_DIR`, `LLM_*`, `OPENSCAD_BIN`,
`MNFT_DATA_DIR` (see `config/dev.exs`).

## Safety

LLM-generated code runs in a guarded worker subprocess: static allow/deny
gates, `python -I -B`, rlimits, wall clock, process-group kill. This is
defence in depth against accidents; it is **not** a hardened sandbox. Do
not expose it to untrusted, anonymous users without kernel-enforced
isolation (containers/gVisor) at the host layer. The OpenSCAD engine has a
smaller surface (a DSL with no exec or network), but treat it the same way.

## License

Apache-2.0 (see LICENSE).
