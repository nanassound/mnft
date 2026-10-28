defmodule MnftCadWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :mnft_cad_web

  # Signed cookie session: carries the anonymous owner id.
  @session_options [
    store: :cookie,
    key: "_mnft_cad_web_key",
    signing_salt: "1cadWebRef2",
    same_site: "Lax"
  ]

  socket "/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [session: @session_options]],
    longpoll: [connect_info: [session: @session_options]]

  plug Plug.Static,
    at: "/",
    from: :mnft_cad_web,
    gzip: not code_reloading?,
    only: MnftCadWeb.static_paths(),
    raise_on_missing_only: code_reloading?

  if code_reloading? do
    socket "/phoenix/live_reload/socket", Phoenix.LiveReloader.Socket
    plug Phoenix.LiveReloader
    plug Phoenix.CodeReloader
  end

  plug Plug.RequestId
  plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint]

  plug Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library()

  plug Plug.MethodOverride
  plug Plug.Head
  plug Plug.Session, @session_options
  plug MnftCadWeb.Router
end
