import Config

# Runtime configuration for production releases. Guarded so dev/test behaviour
# (which configures itself in dev.exs/test.exs) is untouched: for dev and mix
# this file evaluates to nothing.
if config_env() == :prod do
  # --- Endpoint ---------------------------------------------------------------
  # The reference app starts MnftCadWeb.Endpoint unconditionally from its
  # supervision tree (there is no PHX_SERVER gate), so prod must set `server`
  # and the listen address explicitly.
  port = String.to_integer(System.get_env("PORT", "4000"))

  # SECRET_KEY_BASE: a set value is used as-is. Unset or empty means an
  # ephemeral per-boot key, so a bare `docker run` works — but sessions and
  # saved parts then do not survive a restart.
  {secret_key_base, key_ephemeral?} =
    case System.get_env("SECRET_KEY_BASE") do
      value when is_binary(value) and value != "" -> {value, false}
      _ -> {:crypto.strong_rand_bytes(48) |> Base.encode64(), true}
    end

  key_ephemeral? &&
    IO.puts(
      :stderr,
      "[warning] SECRET_KEY_BASE is not set: generated a random key for this " <>
        "boot. Sessions and saved parts will be unreachable after a restart — " <>
        "set SECRET_KEY_BASE for a persistent deployment."
    )

  # Websocket origins: false disables the check for a self-hosted instance,
  # or give an explicit comma-separated scheme+host+port list.
  check_origins =
    case System.get_env("PHX_CHECK_ORIGINS") do
      nil -> false
      "" -> false
      value ->
        value
        |> String.split(",", trim: true)
        |> Enum.map(&String.trim/1)
    end

  config :mnft_cad_web, MnftCadWeb.Endpoint,
    server: true,
    http: [ip: {0, 0, 0, 0}, port: port],
    secret_key_base: secret_key_base,
    url: [
      host: System.get_env("PHX_HOST", "localhost"),
      scheme: System.get_env("PHX_SCHEME", "http"),
      port: String.to_integer(System.get_env("PHX_URL_PORT") || Integer.to_string(port))
    ],
    check_origin: check_origins

  # --- CAD pipeline -----------------------------------------------------------
  # Mirrors config/dev.exs' `config :mnft_cad, :cad` block (env-driven, no .env
  # file parsing: compose injects the environment). Container-appropriate
  # defaults: the uv venv python with build123d, the vendored cad_worker source,
  # and persistent storage under /data. The :events bridge is REQUIRED —
  # without it core stage events never reach Phoenix.PubSub and LiveViews show
  # no progress.
  config :mnft_cad, :cad,
    events: {MnftCadWeb.PubSubBridge, :emit_as_handler, []},
    engine:
      (
        case System.get_env("MNFT_ENGINE", "build123d") do
          "openscad" -> Mnft.Cad.Engines.OpenScad
          _ -> Mnft.Cad.Engines.Build123d
        end
      ),
    worker_python: System.get_env("CAD_WORKER_PYTHON", "/opt/venv/bin/python"),
    worker_cwd: System.get_env("CAD_WORKER_CWD", "/app/cad_worker"),
    exec_concurrency: String.to_integer(System.get_env("CAD_EXEC_CONCURRENCY", "2")),
    exec_timeout_s: String.to_integer(System.get_env("CAD_EXEC_TIMEOUT_S", "60")),
    turn_budget_s: String.to_integer(System.get_env("MNFT_TURN_BUDGET_S", "900")),
    models_dir: System.get_env("CAD_MODELS_DIR", "/data/models"),
    data_dir: System.get_env("MNFT_DATA_DIR", "/data"),
    openscad: [
      bin: System.get_env("OPENSCAD_BIN", "openscad"),
      timeout_s: String.to_integer(System.get_env("OPENSCAD_TIMEOUT_S", "60"))
    ],
    llm: [
      provider: String.to_atom(System.get_env("LLM_PROVIDER", "openai")),
      base_url: System.get_env("LLM_BASE_URL", "https://api.z.ai/api/paas/v4"),
      api_key: {:system, "LLM_API_KEY"},
      text_model: System.get_env("LLM_TEXT_MODEL", "glm-5.3-flash"),
      vision_model: System.get_env("LLM_VISION_MODEL", "glm-4.6v"),
      timeout_s: String.to_integer(System.get_env("LLM_TIMEOUT_S", "600")),
      max_tokens: String.to_integer(System.get_env("LLM_MAX_TOKENS", "32768")),
      repair_max_elapsed_s: String.to_integer(System.get_env("REPAIR_MAX_ELAPSED_S", "240"))
    ],
    references: [
      pdftoppm_bin: System.get_env("PDFTOPPM_BIN", "pdftoppm"),
      pdftotext_bin: System.get_env("PDFTOTEXT_BIN", "pdftotext"),
      fetch_timeout_s: String.to_integer(System.get_env("REF_FETCH_TIMEOUT_S", "30")),
      max_pages: String.to_integer(System.get_env("REF_MAX_PAGES", "3")),
      pdf_dpi: String.to_integer(System.get_env("REF_PDF_DPI", "300")),
      python_bin: System.get_env("REF_PYTHON_BIN", "/opt/venv/bin/python")
    ]
end
