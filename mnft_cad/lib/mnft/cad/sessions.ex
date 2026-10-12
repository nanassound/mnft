defmodule Mnft.Cad.Sessions do
  @moduledoc """
  Session-agent lifecycle. One `Mnft.Cad.Agent` AgentServer per cad session,
  registered with the Jido instance as `"cad_session:<session_id>"`.

  Stage events go through `Mnft.Cad.Events.emit/3` (hosts bridge to their own
  PubSub); event names are `turn_started`, `llm_started`, `llm_done`,
  `exec_started`, `exec_done`, `turn_done` (payload = full result map),
  `turn_failed`, on topic `"cad_session:" <> session_id`.
  """

  alias Mnft.Cad.Events
  alias Mnft.Cad.{Agent, Session}

  def topic(session_id), do: "cad_session:" <> session_id

  def agent_id(session_id), do: "cad_session:" <> session_id

  @doc """
  Find or start the session's agent server. Safe under races (loser re-looks-up).
  """
  def ensure_server(%Session{} = session) do
    id = agent_id(session.id)

    case whereis(session.id) do
      nil ->
        case Jido.AgentServer.start(
               agent: Agent,
               id: id,
               jido: Mnft.Cad.Jido,
               initial_state: initial_state(session)
             ) do
          {:ok, pid} ->
            {:ok, pid}

          _error ->
            case whereis(session.id) do
              nil -> {:error, :agent_start_failed}
              pid -> {:ok, pid}
            end
        end

      pid ->
        {:ok, pid}
    end
  end

  def whereis(session_id) do
    Mnft.Cad.Jido.whereis(agent_id(session_id))
  end

  @doc """
  Request a turn. Returns `{:ok, :started}` or `{:error, reason}` (busy /
  agent failure / the start action rejected the params). The turn's outcome
  arrives via the session's events (`turn_done`).

  # Keep verbatim in sync with the guard string in
  # Mnft.Cad.Actions.TurnStart.run/2.
  """
  @busy_message "a build is already running for this session — wait for it to finish"
  @start_failed_message "could not start the turn — please try again"

  def request_turn(%Session{} = session, message, photos, current) do
    case ensure_server(session) do
      {:ok, server} ->
        if agent_status(server) != :idle do
          {:error, @busy_message}
        else
          signal =
            Jido.Signal.new!(
              "turn.start",
              %{
                session_id: session.id,
                owner_id: session.owner_id,
                message: message,
                photos: photos,
                current: current || %{}
              },
              source: "/cad/" <> session.id
            )

          # The action runs synchronously inside the call: the reply's agent
          # state is :generating only if TurnStart.run actually started the
          # turn; a failed action leaves the agent unchanged (:idle).
          case Jido.AgentServer.call(server, signal, 10_000) do
            {:ok, %{state: %{status: :generating}}} -> {:ok, :started}
            {:ok, _agent} -> {:error, @start_failed_message}
            {:error, %{message: msg}} -> {:error, msg}
            {:error, reason} -> {:error, reason}
            other -> {:error, inspect(other)}
          end
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp agent_status(server) do
    case Jido.AgentServer.state(server) do
      {:ok, state} -> state.agent.state.status
      _ -> :idle
    end
  end

  @doc "Send turn.finish to the session's agent (best effort)."
  def finish_turn(session_id, summary) do
    case whereis(session_id) do
      nil ->
        :ok

      server ->
        signal = Jido.Signal.new!("turn.finish", summary, source: "/cad/" <> session_id)
        Jido.AgentServer.cast(server, signal)
        :ok
    end
  end

  @doc "Thin delegate to `Mnft.Cad.Events.emit/3` so event names stay stable."
  def broadcast(session_id, event, payload), do: Events.emit(session_id, event, payload)

  defp initial_state(session) do
    %{session_id: session.id, owner_id: session.owner_id, status: :idle, turn_started_ms: 0}
  end
end
