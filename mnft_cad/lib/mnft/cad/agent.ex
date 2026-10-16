defmodule Mnft.Cad.Agent do
  @moduledoc """
  One Jido agent per CAD session, started under `Mnft.Cad.Jido` by
  `Mnft.Cad.Sessions.ensure_server/1`.

  The agent owns the session's turn state machine (idle -> generating ->
  idle). Long-running work happens in a supervised Task spawned by
  `turn.start`; the agent itself never blocks for the LLM or the engine.
  """

  use Jido.Agent,
    name: "cad_session",
    description: "Per-session CAD turn state",
    schema: [
      session_id: [type: :string, default: ""],
      owner_id: [type: :string, default: ""],
      status: [type: :atom, default: :idle],
      turn_started_ms: [type: :integer, default: 0],
      # In-flight turn context so UIs can rebuild the pending bubble and the
      # elapsed timer on reconnection; display-only, cleared by turn.finish.
      turn_message: [type: :string, default: ""],
      turn_photos: [type: {:list, {:map, :string, :any}}, default: []]
    ],
    signal_routes: [
      {"turn.start", Mnft.Cad.Actions.TurnStart},
      {"turn.finish", Mnft.Cad.Actions.TurnFinish}
    ]
end

defmodule Mnft.Cad.Actions.TurnStart do
  @moduledoc """
  Validate and kick off one chat turn. Rejects when a turn is already
  in-flight (per-session concurrency cap of one build). The actual pipeline
  runs in a Task under `Mnft.Cad.TurnSupervisor` and reports back with
  `turn.finish`.

  `photos` and `current` arrive straight from the client as JSON, so their
  maps have string keys (`%{"data_url" => ..., "label" => ...}`; `current`
  is the mesh JSON). `stl` is a single optional upload map (`nil`/`{}` =
  none). Downstream consumers accept both key styles.
  """

  use Jido.Action,
    name: "turn_start",
    schema: [
      session_id: [type: :string, required: true],
      owner_id: [type: :string, required: true],
      message: [type: :string, required: true],
      # NimbleOptions `:map` requires atom keys; the client sends string
      # keys, so spell the key type out.
      photos: [type: {:list, {:map, :string, :any}}, default: []],
      stl: [type: {:map, :string, :any}, default: %{}],
      current: [type: {:map, :string, :any}, default: %{}]
    ]

  alias Mnft.Cad.{Events, Images, Turn}

  def run(_params, %{state: %{status: status}} = _context) when status != :idle do
    # Keep verbatim in sync with Mnft.Cad.Sessions.@busy_message.
    {:error, "a build is already running for this session — wait for it to finish"}
  end

  def run(params, _context) do
    case Task.Supervisor.start_child(Mnft.Cad.TurnSupervisor, fn ->
           Turn.run(
             params.session_id,
             params.owner_id,
             params.message,
             params.photos,
             params.stl,
             params.current
           )
         end) do
      {:ok, _pid} ->
        started_ms = System.system_time(:millisecond)
        Events.emit(params.session_id, "turn_started", %{started_ms: started_ms})

        {:ok,
         %{
           status: :generating,
           turn_started_ms: started_ms,
           turn_message: params.message,
           turn_photos: display_photos(params.photos),
           session_id: params.session_id,
           owner_id: params.owner_id
         }}

      {:error, reason} ->
        {:error, "could not start the turn: #{inspect(reason)}"}
    end
  end

  # Display-only photo meta (label + ≤64 KB thumbnail data URL) so a
  # reconnecting UI can rebuild the pending bubble without the raw uploads.
  defp display_photos(photos),
    do: Enum.map(photos, &%{"label" => &1["label"], "thumb" => Images.thumbnail(&1)})
end

defmodule Mnft.Cad.Actions.TurnFinish do
  @moduledoc "Mark the session idle again after a turn completed (success or failure)."
  use Jido.Action,
    name: "turn_finish",
    schema: [
      ok: [type: :boolean, default: false],
      code_missing: [type: :boolean, default: false],
      repaired: [type: :boolean, default: false]
    ]

  def run(_params, _context) do
    {:ok, %{status: :idle, turn_started_ms: 0, turn_message: "", turn_photos: []}}
  end
end
