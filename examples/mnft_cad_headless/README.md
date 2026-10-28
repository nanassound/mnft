# mnft_cad_headless

A headless reference for the `mnft_cad` core, driven entirely from the
command line. One command runs 2 owners × 2 sessions = 4 CAD sessions with
all first turns in flight at once, then one follow-up turn per session, and
prints everything that happened. This is the shape of a host that embeds
the core: a job server, a bot, a batch pipeline.

## What it demonstrates

| Core API | Where |
|---|---|
| Host-owned config under `config :mnft_cad, :cad` | `config/config.exs` |
| Events seam `{mod, fun, args}` → `apply(mod, fun, [session_id, event, payload])` | `MnftCadHeadless.Collector.handle_event/3` |
| Buffering + `await` of a session's terminal event (`turn_done` / `turn_failed`) | `MnftCadHeadless.Collector.await/2` |
| `Mnft.Cad.create_session/2` per owner | `MnftCadHeadless.run/0` |
| `Mnft.Cad.Sessions.request_turn/4` → `{:ok, :started}` | `MnftCadHeadless.run/0` |
| `turn_done` payload fields (`ok`, `reply`, `error`, `artifacts.stl/step/glb/model_id`, `mesh["volume_mm3"]`, `meta`) | summary table |
| Store reads: `Mnft.Cad.list_sessions/1`, `get_model/2`, `latest_model/1` | end of the run |
| Artifacts on disk under `data/models/<owner_id>/<model_id>/` | real mode |

Depending on `:mnft_cad` starts the core's whole supervision tree (ETS
store with journal replay, the Jido agent instance, the ExecLimiter build
pool, the TurnSupervisor); this app has no `mod` of its own.

## Run it offline

```bash
cd mnft_cad_headless
mix deps.get
MNFT_HEADLESS_FAKE=1 mix run -e "MnftCadHeadless.run()"
```

The offline run needs no API key, Python, or OpenSCAD.
`MNFT_HEADLESS_FAKE=1` points the two seams the core ships for embedders at
their scripted versions, `Mnft.Cad.LLMFake` behind `:llm_module` and
`Mnft.Cad.EngineFake` behind `:engine`, and seeds each with more entries
than the happy path needs. Everything else is the real pipeline: real
Jido agents, TurnSupervisor, store, journal, events. It is deterministic,
so CI runs it (see `.github/workflows/ci.yml`).

## Run it for real

```bash
cp ../../.env.example .env      # then set LLM_API_KEY
mix deps.get
mix run -e "MnftCadHeadless.run()"
```

Needs the build123d worker (`cd ../../core/cad_worker && uv venv --python 3.12 &&
uv pip install -e .`) or `MNFT_ENGINE=openscad` with the binary on PATH.
Real turns take minutes; progress streams as one log line per stage event.

## The concurrency contract

* Turns across sessions run concurrently: the run fires all four first
  turns back-to-back and awaits them with one task per session.
* One in-flight turn **per session**. A second `request_turn/4` while a
  turn is running returns
  `{:error, "a build is already running for this session — wait for it to finish"}`,
  which is why the run awaits each turn before sending its follow-up.
* `MnftCadHeadless.Collector.await/2` delivers each turn's terminal event
  exactly once: awaiting consumes it, so the same helper can await turn 1
  and then turn 2 of one session.
* Two timing details a host must respect:
  * `turn_done` is emitted just **before** the session agent flips back to
    idle (the finish is a cast that lands after the terminal event), so
    after awaiting the terminal event, confirm idle with
    `Mnft.Cad.Sessions.turn_info/1` before requesting the next turn; the
    run does exactly that.
  * Real engine builds are FIFO-capped across all sessions by
    `exec_concurrency` (`Mnft.Cad.ExecLimiter`), so N sessions can be
    mid-LLM while only N_builds are mid-exec.

## Storage

The default `Mnft.Cad.Store.Ets` journals every turn (one JSON line per
turn, fsynced) to `data/mnft_cad.jsonl` and replays it on boot: kill the
host mid-run and the sessions, messages and models come back. Model
artifact files live under `data/models/<owner_id>/<model_id>/`; the
journal stores their metadata only.

The full embedding guide is [`mnft_cad/README.md`](../../core/mnft_cad/README.md).
