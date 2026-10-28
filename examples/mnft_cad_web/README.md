# mnft_cad_web

Open-source reference Phoenix app for [`mnft_cad`](../../core/mnft_cad): chat-to-CAD in
the browser. Every visitor is an anonymous owner identified by a signed
session cookie, and all data (sessions, messages, models, downloads) is
scoped to that owner.


## Run

```
cd examples/mnft_cad_web
mix setup      # deps.get + asset build
mix phx.server # http://localhost:4200
```

A real build turn needs a working `cad_worker` Python environment and an LLM
API key (see `config/dev.exs`, env-driven: `LLM_API_KEY`, `CAD_WORKER_PYTHON`,
`CAD_WORKER_CWD`, ...).

## Layout

- `lib/mnft_cad_web/owner_plug.ex`: assigns `:owner_id` from the cookie (mints one when absent)
- `lib/mnft_cad_web/pubsub_bridge.ex`: bridges core stage events into Phoenix.PubSub (`config :mnft_cad, :cad, events: {MnftCadWeb.PubSubBridge, :emit_as_handler, []}`)
- `lib/mnft_cad_web/model_url.ex`: artifact URL helpers (`/m/<id>/model.stl` by default, `:artifact_url_prefix` overridable)
- `lib/mnft_cad_web/live/`: `HomeLive`, `SessionIndexLive`, `CadLive`
- `lib/mnft_cad_web/controllers/cad_model_controller.ex`: owner-scoped artifact downloads

## Tests

```
mix test
```

Uses the core's `LLMFake`/`EngineFake` seams; the suite runs without Python
or an API key.
