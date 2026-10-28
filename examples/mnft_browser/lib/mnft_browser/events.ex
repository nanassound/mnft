defmodule MnftBrowser.Events do
  @moduledoc """
  The `{mod, fun, args}` events seam: every core stage event goes to the
  page as one Popcorn message. Wire format matches the closed SaaS message
  shape `%{event:, payload:, session_id:}` so handlers stay compatible.
  Payloads are Jason-safe by construction (atom keys, binaries, numbers,
  lists) — no rescue.
  """

  alias Popcorn.JS

  def to_page(session_id, event, payload) do
    JS.send(%{
      type: "cad-event",
      json: Jason.encode!(%{event: event, session_id: session_id, payload: payload})
    })
  end
end
