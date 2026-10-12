import Config

config :mnft_cad_web, MnftCadWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4200],
  check_origin: false,
  code_reloader: true,
  debug_errors: true,
  secret_key_base: "dxV1cKfnRKfFP3tZYwCSPX4EZ5FPnYBMTJjnCjqUg7mOR9yzsWqE6L3PjqCVRxQM",
  watchers: [
    esbuild: {Esbuild, :install_and_run, [:mnft_cad_web, ~w(--sourcemap=inline --watch)]},
    tailwind: {Tailwind, :install_and_run, [:mnft_cad_web, ~w(--watch)]}
  ]

config :logger, :default_formatter, format: "[$level] $message\n"
config :phoenix, :stacktrace_depth, 20
config :phoenix, :plug_init_mode, :runtime

config :phoenix_live_view,
  debug_heex_annotations: true,
  debug_attributes: true,
  enable_expensive_runtime_checks: true

# Reference app defaults for the core pipeline. .env is parsed here (app dir
# wins over repo root; real environment variables win over both) because
# config evaluates BEFORE req_llm's own dotenvy runs, so plain System.get_env
# would miss .env-only values. Paths are relative to this app dir. The
# :events key bridges the core's stage events into this app's PubSub so
# LiveViews can subscribe to Mnft.Cad.Sessions.topic(session_id).
load_env_file = fn path, acc ->
  case File.read(path) do
    {:ok, content} ->
      content
      |> String.split("\n")
      |> Enum.reduce(acc, fn line, acc ->
        case String.split(String.trim(line), "=", parts: 2) do
          [k, v] ->
            k = String.trim(k)

            if k != "" and not String.starts_with?(k, "#") do
              v =
                v
                |> String.trim()
                |> then(fn v ->
                  if String.length(v) > 1 and String.starts_with?(v, "\"") and
                       String.ends_with?(v, "\""),
                     do: String.slice(v, 1..-2//1),
                     else: v
                end)

              Map.put_new(acc, k, v)
            else
              acc
            end

          _ ->
            acc
        end
      end)

    _ ->
      acc
  end
end

env =
  Path.expand("../.env", File.cwd!())
  |> then(&load_env_file.(&1, %{}))
  |> then(&load_env_file.(Path.expand(".env", File.cwd!()), &1))

getenv = fn name, default -> System.get_env(name) || env[name] || default end

config :mnft_cad, :cad,
  events: {MnftCadWeb.PubSubBridge, :emit_as_handler, []},
  engine:
    (
      case getenv.("MNFT_ENGINE", "build123d") do
        "openscad" -> Mnft.Cad.Engines.OpenScad
        _ -> Mnft.Cad.Engines.Build123d
      end
    ),
  worker_python: getenv.("CAD_WORKER_PYTHON", "../cad_worker/.venv/bin/python"),
  worker_cwd: getenv.("CAD_WORKER_CWD", "../cad_worker"),
  exec_concurrency: String.to_integer(getenv.("CAD_EXEC_CONCURRENCY", "2")),
  exec_timeout_s: String.to_integer(getenv.("CAD_EXEC_TIMEOUT_S", "60")),
  turn_budget_s: String.to_integer(getenv.("MNFT_TURN_BUDGET_S", "900")),
  models_dir: getenv.("CAD_MODELS_DIR", "data/models"),
  data_dir: getenv.("MNFT_DATA_DIR", "data"),
  openscad: [
    bin: getenv.("OPENSCAD_BIN", "openscad"),
    timeout_s: String.to_integer(getenv.("OPENSCAD_TIMEOUT_S", "60"))
  ],
  llm: [
    provider: String.to_atom(getenv.("LLM_PROVIDER", "openai")),
    base_url: getenv.("LLM_BASE_URL", "https://api.z.ai/api/paas/v4"),
    api_key: {:system, "LLM_API_KEY"},
    text_model: getenv.("LLM_TEXT_MODEL", "glm-5.3-flash"),
    vision_model: getenv.("LLM_VISION_MODEL", "glm-4.6v"),
    timeout_s: String.to_integer(getenv.("LLM_TIMEOUT_S", "600")),
    max_tokens: String.to_integer(getenv.("LLM_MAX_TOKENS", "32768")),
    repair_max_elapsed_s: String.to_integer(getenv.("REPAIR_MAX_ELAPSED_S", "240"))
  ],
  references: [
    pdftoppm_bin: getenv.("PDFTOPPM_BIN", "pdftoppm"),
    pdftotext_bin: getenv.("PDFTOTEXT_BIN", "pdftotext"),
    fetch_timeout_s: String.to_integer(getenv.("REF_FETCH_TIMEOUT_S", "30")),
    max_pages: String.to_integer(getenv.("REF_MAX_PAGES", "3")),
    pdf_dpi: String.to_integer(getenv.("REF_PDF_DPI", "300")),
    python_bin:
      getenv.(
        "REF_PYTHON_BIN",
        Path.expand("../../cad_worker/.venv/bin/python", __DIR__)
      )
  ]
