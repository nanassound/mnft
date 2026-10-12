defmodule MnftCadWeb.PubSubBridge do
  @moduledoc """
  Bridges the core's stage events (`Mnft.Cad.Events`) into this app's
  Phoenix.PubSub.

  Wired via `config :mnft_cad, :cad, events: {MnftCadWeb.PubSubBridge, :emit_as_handler, []}`;
  the core calls `apply(mod, fun, [session_id, event, payload | args])`, so
  `emit_as_handler/3` is the arity-3 wrapper.

  Broadcast shape (keep stable — LiveViews match on `event`):

      Phoenix.PubSub.broadcast(pubsub, "cad_session:" <> session_id,
        %{event: event, payload: payload, session_id: session_id})
  """

  def emit_as_handler(session_id, event, payload) do
    broadcast(session_id, event, payload)
  end

  @doc "Subscribe a LiveView process to a session's stage-event topic."
  def subscribe(session_id) do
    Phoenix.PubSub.subscribe(pubsub(), Mnft.Cad.Sessions.topic(session_id))
  end

  def broadcast(session_id, event, payload) do
    Phoenix.PubSub.broadcast(
      pubsub(),
      Mnft.Cad.Sessions.topic(session_id),
      %{event: event, payload: payload, session_id: session_id}
    )
  end

  defp pubsub do
    Application.get_env(:mnft_cad_web, :pubsub_server, MnftCadWeb.PubSub)
  end
end
