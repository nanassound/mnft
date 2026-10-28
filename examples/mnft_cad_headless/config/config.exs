import Config

config :logger, :default_formatter, format: "[$level] $message\n"

# Jido instance (per-session turn agents)
config :mnft_cad, Mnft.Cad.Jido, agent_pools: []

# Long LLM timeouts, mirrors mnft_cad_web/config/config.exs
config :req_llm,
  receive_timeout: 600_000,
  thinking_timeout: 600_000,
  load_dotenv: true,
  redact_context: true,
  warn_unverified_models: false

# .env is parsed here (app dir wins over repo root; real environment
# variables win over both) because config evaluates BEFORE req_llm's own
# dotenvy runs, so plain System.get_env would miss .env-only values. Paths
# are relative to this app dir. The host owns this config: everything the
# core reads lives under `config :mnft_cad, :cad` below.
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

# "" (or whitespace-only) env values mean "use the provider's own default
# endpoint", so they normalize to nil instead of overriding it.
blank_to_nil = fn
  url when is_binary(url) ->
    case String.trim(url) do
      "" -> nil
      trimmed -> trimmed
    end

  _ ->
    nil
end

# MNFT_HEADLESS_FAKE=1 runs the identical pipeline against the scripted
# seams the core ships for embedders and tests (Mnft.Cad.LLMFake behind
# :llm_module, Mnft.Cad.EngineFake behind :engine): no API key, no Python
# worker, no OpenSCAD, fully deterministic. Without the flag the example is
# a plain real-mode embedder.
fake? = System.get_env("MNFT_HEADLESS_FAKE") == "1"

engine =
  if fake? do
    Mnft.Cad.EngineFake
  else
    case getenv.("MNFT_ENGINE", "build123d") do
      "openscad" -> Mnft.Cad.Engines.OpenScad
      _ -> Mnft.Cad.Engines.Build123d
    end
  end

cad =
  [
    # The events seam: the core calls apply(mod, fun, [session_id, event,
    # payload | args]) for every stage event of every session. Here the
    # collector logs one line per event and buffers terminal payloads for
    # await/2 — swap it for PubSub, a message queue, whatever the host has.
    events: {MnftCadHeadless.Collector, :handle_event, []},
    engine: engine,
    worker_python: getenv.("CAD_WORKER_PYTHON", "../../core/cad_worker/.venv/bin/python"),
    worker_cwd: getenv.("CAD_WORKER_CWD", "../../core/cad_worker"),
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
      base_url: blank_to_nil.(getenv.("LLM_BASE_URL", "https://api.z.ai/api/paas/v4")),
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
      python_bin: getenv.("REF_PYTHON_BIN", "../../core/cad_worker/.venv/bin/python")
    ]
  ]
  # The scripted LLM is the offline mode's only extra seam; without it the
  # core's default (Mnft.Cad.LLM via req_llm) applies.
  |> then(fn kw -> if fake?, do: Keyword.put(kw, :llm_module, Mnft.Cad.LLMFake), else: kw end)

config :mnft_cad, :cad, cad
