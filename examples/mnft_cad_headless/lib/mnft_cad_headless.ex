defmodule MnftCadHeadless do
  @moduledoc """
  Headless `mnft_cad` — the core with no Phoenix, no UI, driven exactly the
  way an embedding host would drive it.

  `run/0` demonstrates the whole surface in one pass:

    * host-owned config for the core (`config :mnft_cad, :cad`, see
      `config/config.exs`),
    * 2 owners × 2 sessions = 4 sessions, all first turns requested
      back-to-back so they run concurrently,
    * one follow-up turn per session — sequential within a session, because
      the core runs one in-flight turn per session (the busy gate),
    * stage events collected through the `{mod, fun, args}` events seam
      (`MnftCadHeadless.Collector`, with `await/2` per session),
    * store reads (`list_sessions/1`, `get_model/2`, `latest_model/1`) and
      artifact paths taken from the `turn_done` payload.

  Offline, deterministic, zero prerequisites (no API key, no Python worker,
  no OpenSCAD — scripted `Mnft.Cad.LLMFake` + `Mnft.Cad.EngineFake` sit
  behind the core's own seams, so the real pipeline still runs):

      MNFT_HEADLESS_FAKE=1 mix run -e "MnftCadHeadless.run()"

  For real turns (needs `LLM_API_KEY` in the environment or `.env`, and the
  configured engine — build123d worker or OpenSCAD):

      mix run -e "MnftCadHeadless.run()"
  """

  alias Mnft.Cad, as: Cad
  alias Mnft.Cad.{Config, Sessions}
  alias MnftCadHeadless.Collector

  @jobs [
    {"agent-alpha", "a 30 mm cube with a 12 mm hole through the center", "make it 40 mm tall"},
    {"agent-alpha", "a 60 x 40 x 10 mm plate with four M4 holes at the corners",
     "make the plate 5 mm thick"},
    {"agent-beta", "a 40 mm hexagonal pen holder with a 3 mm wall", "make the wall 5 mm thick"},
    {"agent-beta", "a 25 mm radius pulley with a 6 mm bore", "widen the bore to 8 mm"}
  ]

  @spec run() :: :ok
  def run do
    # single source of truth for the mode: whatever config actually wired in
    fake? = Cad.llm_module() == Mnft.Cad.LLMFake

    IO.puts(header(fake?))

    start_collector()
    if fake?, do: seed_fakes()

    jobs =
      for {owner, first, followup} <- @jobs do
        {:ok, session} = Cad.create_session(owner)
        {session, owner, first, followup}
      end

    # round 1: every session's first turn in flight at once
    round1 = jobs |> start_turns(2) |> await_all()
    # round 2: one follow-up per session that reached a terminal event —
    # sessions still running from round 1 stay busy and are skipped
    round2 = round1 |> finished_jobs() |> start_turns(3) |> await_all()

    events =
      Map.new(Collector.snapshot().sessions, fn {sid, entry} -> {sid, length(entry.events)} end)

    rows = Enum.map(round1, &row(&1, 1, events)) ++ Enum.map(round2, &row(&1, 2, events))

    # stage-event lines are logged asynchronously; flush them out so the
    # summary starts on a clean boundary
    Logger.flush()
    print_summary(rows)
    print_store(jobs, rows)

    Logger.flush()
    :ok
  end

  # --- turn rounds ---------------------------------------------------------------

  # Request a turn per job, skipping any that cannot start. Before the
  # request the session is confirmed idle: `turn_done`/`turn_failed` arrive
  # just BEFORE the agent's turn.finish cast flips it back to idle, so a
  # host that awaits the terminal event must still wait for idle or the
  # busy gate can legitimately reject the next turn.
  defp start_turns(jobs, msg_index) do
    Enum.filter(jobs, fn {session, _, _, _} = job ->
      wait_until_idle(session.id) and start_turn(session, elem(job, msg_index))
    end)
  end

  defp start_turn(session, message) do
    case Sessions.request_turn(session, message, [], %{}, %{}) do
      {:ok, :started} ->
        true

      {:error, reason} ->
        IO.puts("[#{short(session.id)}] failed to start turn: #{reason}")
        false
    end
  end

  # All started sessions awaited concurrently: one task per session, all in
  # flight at the same time. `await/2` parks until the session's terminal
  # event (or returns it from the buffer if it already arrived).
  defp await_all(started)

  defp await_all([]), do: []

  defp await_all(started) do
    await_timeout_ms = (Config.get(:turn_budget_s, 900) + 60) * 1000

    started
    |> Task.async_stream(
      fn {session, _, _, _} -> {session.id, Collector.await(session.id, await_timeout_ms)} end,
      timeout: await_timeout_ms + 10_000,
      on_timeout: :kill_task,
      max_concurrency: length(started)
    )
    # Task.async_stream preserves input order, so the zip reattaches the job
    # even for killed/timed-out tasks
    |> Enum.zip(started)
    |> Enum.map(fn
      # Enum.zip yields {stream_item, job}; stream items are
      # {:ok, task_value} / {:exit, reason}, and the task value is
      # {session_id, Collector.await result}
      {{:ok, {_sid, {:ok, result}}}, job} -> {:ok, job, result}
      {{:exit, reason}, job} -> {:timeout, job, reason}
    end)
  end

  defp finished_jobs(round_results), do: for({:ok, job, _} <- round_results, do: job)

  defp wait_until_idle(session_id, tries \\ 200)

  defp wait_until_idle(_session_id, 0), do: false

  defp wait_until_idle(session_id, tries) do
    case Sessions.turn_info(session_id) do
      %{running: false} ->
        true

      _ ->
        Process.sleep(5)
        wait_until_idle(session_id, tries - 1)
    end
  end

  # --- fake mode -------------------------------------------------------------------

  # Scripts MORE entries than the happy path needs (8 turns) so surprise
  # repair/recheck calls pop a spare instead of exhausting the FIFO. The
  # heights increase per pop, and a session's turn 2 pops strictly later
  # than its turn 1 (one in-flight turn per session), so every turn builds
  # something new — the noop-recheck's extra LLM call never fires.
  defp seed_fakes do
    entries = length(@jobs) * 2 + 2
    start_fake(Mnft.Cad.LLMFake)
    start_fake(Mnft.Cad.EngineFake)
    Mnft.Cad.LLMFake.set_script(Enum.map(1..entries, &llm_ok/1))
    Mnft.Cad.EngineFake.set_script(Enum.map(1..entries, &engine_ok/1))
  end

  defp start_fake(mod) do
    case mod.start_link([]) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end
  end

  # Each reply carries a complete fenced code block, so code extraction
  # always succeeds.
  defp llm_ok(i) do
    {:ok,
     %{
       reply: "Part ##{i} (scripted).\n```python\npart = Box(30, 30, #{10 + i})\n```",
       reasoning: "scripted",
       finish_reason: :stop
     }}
  end

  defp engine_ok(i) do
    h = 10.0 + i
    model_id = "fake" <> String.pad_leading(Integer.to_string(i), 4, "0")

    %{
      ok: true,
      stage: :exec,
      error: nil,
      artifacts: %{
        model_id: model_id,
        stl: "/tmp/mnft-headless/#{model_id}/model.stl",
        step: "/tmp/mnft-headless/#{model_id}/model.step",
        glb: "/tmp/mnft-headless/#{model_id}/model.glb"
      },
      mesh: %{"triangles" => 12, "bbox_mm" => [30.0, 30.0, h], "volume_mm3" => 900.0 * h},
      exec_ms: 250
    }
  end

  # --- output ----------------------------------------------------------------------

  defp header(fake?) do
    mode = if fake?, do: "fake", else: "real"

    String.pad_trailing(
      "== mnft_cad headless — mode: #{mode}, engine: #{inspect(Cad.engine())} ",
      74,
      "="
    )
  end

  defp start_collector do
    case Collector.start_link([]) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end
  end

  defp print_summary(rows) do
    IO.puts(String.duplicate("-", 74))
    print_table(rows)
  end

  defp row({:ok, {session, owner, _, _}, %{terminal: "turn_done", payload: p}}, turn, events) do
    {ok, note} =
      if p[:ok],
        do: {"yes", snippet(p[:reply])},
        else: {"no", "error: #{p[:error]}"}

    build_row(session, owner, turn, ok, p, events, note)
  end

  defp row({:ok, {session, owner, _, _}, %{terminal: "turn_failed", payload: p}}, turn, events) do
    build_row(session, owner, turn, "no", p, events, "error: #{p[:error] || "turn_failed"}")
  end

  defp row({:timeout, {session, owner, _, _}, reason}, turn, events) do
    build_row(
      session,
      owner,
      turn,
      "timeout",
      %{},
      events,
      "turn still in flight or lost (#{inspect(reason)})"
    )
  end

  defp build_row(session, owner, turn, ok, payload, events, note) do
    artifacts = payload[:artifacts] || %{}

    %{
      owner: owner,
      sid: session.id,
      session: short(session.id),
      turn: turn,
      ok: ok,
      model_id: artifacts[:model_id],
      volume: payload[:mesh]["volume_mm3"],
      events: events[session.id] || 0,
      stl: artifacts[:stl],
      note: note
    }
  end

  defp print_table(rows) do
    header = ["owner", "session", "turn", "ok", "model_id", "volume_mm3", "events", "stl"]

    cells =
      Enum.map(rows, fn r ->
        [
          r.owner,
          r.session,
          Integer.to_string(r.turn),
          r.ok,
          dash(r.model_id),
          fmt_num(r.volume),
          Integer.to_string(r.events),
          dash(r.stl)
        ]
      end)

    widths =
      header
      |> Enum.with_index()
      |> Enum.map(fn {h, i} ->
        Enum.max([String.length(h) | Enum.map(cells, &String.length(Enum.at(&1, i)))])
      end)

    render = fn cols ->
      Enum.map_join(Enum.zip(cols, widths), "  ", &String.pad_trailing(elem(&1, 0), elem(&1, 1)))
    end

    IO.puts(render.(header))

    Enum.each(Enum.zip(cells, rows), fn {cols, row} ->
      IO.puts(render.(cols))
      IO.puts("    #{row.note}")
    end)
  end

  defp print_store(jobs, rows) do
    IO.puts(String.duplicate("-", 74))

    jobs
    |> Enum.map(&elem(&1, 1))
    |> Enum.uniq()
    |> Enum.each(fn owner ->
      sessions = Cad.list_sessions(owner)

      listing =
        Enum.map_join(sessions, ", ", fn s -> "\"#{truncate(s.title)}\" (#{short(s.id)})" end)

      IO.puts("#{owner} sessions (#{length(sessions)}): #{listing}")
    end)

    case Enum.find(rows, &(&1.ok == "yes" and is_binary(&1.model_id))) do
      nil ->
        IO.puts("no successful turn — nothing to read back from the store")

      row ->
        model = Cad.get_model(row.owner, row.model_id)
        IO.puts("get_model(\"#{row.owner}\", \"#{row.model_id}\") -> #{inspect(model)}")
        IO.puts("latest_model(\"#{row.sid}\") -> #{model_line(Cad.latest_model(row.sid))}")
    end
  end

  defp model_line(nil), do: "nil"

  defp model_line(model),
    do:
      "#{model.id} (volume_mm3: #{inspect(model.mesh["volume_mm3"])}, has_glb: #{model.has_glb})"

  defp snippet(reply) when is_binary(reply),
    do: reply |> String.replace("\n", " ") |> String.slice(0, 80)

  defp snippet(_), do: "-"

  defp fmt_num(v) when is_float(v), do: :erlang.float_to_binary(v, decimals: 1)
  defp fmt_num(v) when is_integer(v), do: Integer.to_string(v)
  defp fmt_num(_), do: "-"

  defp dash(nil), do: "-"
  defp dash(v), do: v

  defp truncate(text) when is_binary(text) do
    if String.length(text) > 32, do: String.slice(text, 0, 32) <> "…", else: text
  end

  defp short(session_id), do: String.slice(session_id, 0, 8)
end
