defmodule Mnft.Cad.Events do
  @moduledoc """
  Stage events for one session, delivered to the configured handler.

  The core never depends on a PubSub: hosts bridge to their own transport by
  setting `:events` under `:mnft_cad, :cad` config to `{mod, fun, args}`;
  the call becomes `apply(mod, fun, [session_id, event, payload | args])`.
  The closed SaaS broadcasts to Phoenix.PubSub topic
  `"cad_session:" <> session_id` with a `%{event:, payload:, session_id:}`
  message — keep that shape stable, LiveViews match on `event`.

  Events: `turn_started`, `llm_started`, `llm_done`, `exec_started`,
  `exec_done`, `turn_done` (payload = full result map), `turn_failed`.
  Reference fetching adds `fetch_started` (`%{count: n}`) and `fetch_done`
  (`%{fetched:, pages:, failed: [%{url:, reason:}]}`) before the first
  `llm_started`.
  Also emits `[:mnft_cad, :cad, :event]` telemetry.
  """

  def emit(session_id, event, payload) do
    :telemetry.execute([:mnft_cad, :cad, :event], %{}, %{
      event: event,
      session_id: session_id
    })

    case Mnft.Cad.Config.get(:events) do
      {mod, fun, args} -> apply(mod, fun, [session_id, event, payload | args])
      _ -> :ok
    end

    :ok
  end
end
