defmodule Mnft.Cad.ReferencesFake do
  @moduledoc """
  Scripted reference fetcher for tests, behind the `:references_module` seam.
  URL-less messages pass through untouched; a message containing a URL
  produces one fake datasheet page plus the reference block, and emits the
  same `fetch_started` / `fetch_done` events the real module emits.
  """

  alias Mnft.Cad.Events

  @url_re ~r{https?://[^\s<>"')\]]+}i

  def enrich(session_id, message) do
    case Regex.run(@url_re, message) do
      nil ->
        {message, [], []}

      [url0] ->
        url = Regex.replace(~r/[.,;:!?]+\z/, url0, "")
        Events.emit(session_id, "fetch_started", %{count: 1})

        png = <<137, 80, 78, 71>>

        image = %{
          data_url: "data:image/png;base64," <> Base.encode64(png),
          media_type: "image/png",
          bytes: png,
          size: byte_size(png),
          label: "reference"
        }

        text = "Tiptop z-rails: 84 HP = 427 mm length, 23.8 mm deep"
        msg = message <> "\n\n[Reference datasheet #{url} — 1 page(s) attached as images]\n" <> text

        Events.emit(session_id, "fetch_done", %{fetched: 1, pages: 1, failed: []})

        {msg, [image], [%{"url" => url, "pages" => 1, "text" => text}]}
    end
  end
end
