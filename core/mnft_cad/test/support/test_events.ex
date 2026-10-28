defmodule Mnft.Cad.TestEvents do
  @moduledoc """
  Test event handler: forwards `Mnft.Cad.Events.emit/3` calls to the pid set
  with `set/1` as `%{event:, payload:, session_id:}` messages (the same shape
  the SaaS PubSub bridge uses). Configured as `:events` in config/test.exs.
  """

  def set(pid), do: Application.put_env(:mnft_cad, :test_events_pid, pid)

  def unset, do: Application.delete_env(:mnft_cad, :test_events_pid)

  def emit(session_id, event, payload) do
    case Application.get_env(:mnft_cad, :test_events_pid) do
      nil -> :ok
      pid -> send(pid, %{event: event, payload: payload, session_id: session_id})
    end

    :ok
  end
end
