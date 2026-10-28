defmodule MnftCadHeadless.Collector do
  @moduledoc """
  The core's `{mod, fun, args}` events seam, made concrete.

  `config :mnft_cad, :cad, events: {MnftCadHeadless.Collector, :handle_event, []}`
  makes the core call `apply(MnftCadHeadless.Collector, :handle_event,
  [session_id, event, payload])` for every stage event of every session —
  `turn_started`, `llm_started`, `llm_done`, `exec_started`, `exec_done`,
  `turn_done`, `turn_failed`. Swap this module for a PubSub bridge, a
  message queue, anything; the seam is the whole integration point.

  Events are recorded for ANY session id — sessions never pre-register — so
  a `turn_done` that arrives before a caller calls `await/2` is buffered,
  not lost. `await/2` returns the session's terminal event immediately if
  it already happened, otherwise parks the caller until it does. The
  terminal is delivered exactly once per turn: awaiting consumes it, so a
  session's NEXT turn can await its own terminal — without consumption the
  buffer would hand back the previous turn's result forever.
  """

  use GenServer
  require Logger

  @terminal_events ["turn_done", "turn_failed"]

  @doc "Starts the collector under the name `MnftCadHeadless.Collector`."
  def start_link(_opts), do: GenServer.start_link(__MODULE__, new_state(), name: __MODULE__)

  # --- the events seam (runs in the core's turn process) -----------------------

  def handle_event(session_id, event, payload) do
    # first 8 chars of the session id make cross-session interleaving visible
    Logger.info("[#{short(session_id)}] #{event}")

    # a cast to an unregistered name is a no-op, so a turn that fires before
    # start_link/1 can never crash on the seam
    GenServer.cast(__MODULE__, {:event, session_id, event, payload})
    :ok
  end

  # --- consumer API ------------------------------------------------------------

  @doc """
  Blocks until `session_id`'s terminal event (`turn_done` or `turn_failed`),
  then returns `{:ok, %{terminal: event, payload: payload}}`. Returns from
  the buffer when the turn already finished. Delivers each turn's terminal
  exactly once — the buffer hands back the PREVIOUS turn's result only if
  nobody awaited it. `timeout` in ms.
  """
  def await(session_id, timeout \\ :infinity) do
    GenServer.call(__MODULE__, {:await, session_id}, timeout)
  end

  @doc "Raw state: per-session event names (newest first) and terminal result."
  def snapshot, do: GenServer.call(__MODULE__, :snapshot)

  # --- server ------------------------------------------------------------------

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_cast({:event, session_id, event, payload}, %{sessions: sessions, waiters: waiters}) do
    entry =
      sessions
      |> Map.get(session_id, %{events: [], result: nil})
      |> Map.update!(:events, &[event | &1])
      |> then(fn entry ->
        if event in @terminal_events,
          do: %{entry | result: %{terminal: event, payload: payload}},
          else: entry
      end)

    state = %{sessions: Map.put(sessions, session_id, entry), waiters: waiters}

    state =
      if entry.result do
        {parked, waiters} = Map.pop(waiters, session_id, [])
        Enum.each(parked, &GenServer.reply(&1, {:ok, entry.result}))

        # consumed by the parked awaiters; with nobody parked it stays
        # buffered for the await that comes later
        entry = if parked == [], do: entry, else: %{entry | result: nil}
        %{sessions: Map.put(state.sessions, session_id, entry), waiters: waiters}
      else
        state
      end

    {:noreply, state}
  end

  @impl true
  def handle_call({:await, session_id}, from, %{sessions: sessions, waiters: waiters}) do
    case sessions[session_id] do
      %{result: result} = entry when not is_nil(result) ->
        # consume: the next turn of this session must await its own terminal
        state = %{
          sessions: Map.put(sessions, session_id, %{entry | result: nil}),
          waiters: waiters
        }

        {:reply, {:ok, result}, state}

      _ ->
        {:noreply,
         %{sessions: sessions, waiters: Map.update(waiters, session_id, [from], &[from | &1])}}
    end
  end

  def handle_call(:snapshot, _from, state), do: {:reply, state, state}

  defp short(session_id), do: String.slice(session_id, 0, 8)

  defp new_state, do: %{sessions: %{}, waiters: %{}}
end
