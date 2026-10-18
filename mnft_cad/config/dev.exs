import Config

# "" (or whitespace-only) env values mean "use the provider's own default
# endpoint", so they normalize to nil instead of overriding it.
blank_to_nil = fn
  url when is_binary(url) ->
    case String.trim(url) do
      "" -> nil
      trimmed -> trimmed
    end

  _ -> nil
end

# Default pipeline config for running the core directly (tests, demos). Hosts
# override everything via `:mnft_cad, :cad` application config; the provider
# endpoint and models are env-driven so a provider/model swap is a config
# change, never code.
config :mnft_cad, :cad,
  engine:
    (
      case System.get_env("MNFT_ENGINE", "build123d") do
        "openscad" -> Mnft.Cad.Engines.OpenScad
        "smlibpy" -> Mnft.Cad.Engines.Smlibpy
        _ -> Mnft.Cad.Engines.Build123d
      end
    ),
  worker_python: System.get_env("CAD_WORKER_PYTHON", "../cad_worker/.venv/bin/python"),
  worker_cwd: System.get_env("CAD_WORKER_CWD", "../cad_worker"),
  exec_concurrency: String.to_integer(System.get_env("CAD_EXEC_CONCURRENCY", "2")),
  exec_timeout_s: String.to_integer(System.get_env("CAD_EXEC_TIMEOUT_S", "60")),
  turn_budget_s: String.to_integer(System.get_env("MNFT_TURN_BUDGET_S", "900")),
  models_dir: System.get_env("CAD_MODELS_DIR", "data/models"),
  data_dir: System.get_env("MNFT_DATA_DIR", "data"),
  openscad: [
    bin: System.get_env("OPENSCAD_BIN", "openscad"),
    timeout_s: String.to_integer(System.get_env("OPENSCAD_TIMEOUT_S", "60"))
  ],
  # FreeCAD headless CAM (G-code generation after a successful build123d
  # build). toolbits_dir defaults to this app's priv/cam/toolbits.
  cam: [
    freecad_cmd: System.get_env("MNFT_FREECAD_CMD", "/Applications/FreeCAD.app/Contents/MacOS/FreeCAD"),
    timeout_s: String.to_integer(System.get_env("MNFT_CAM_TIMEOUT_S", "180"))
  ],
  # Only the keys that differ from Mnft.Cad.References' @defaults (pdf_dpi is
  # already 300 there). The trim helper needs the cad_worker venv python for
  # Pillow; relative like :worker_python because `mix run` here runs with the
  # mnft_cad dir as cwd.
  references: [
    python_bin: System.get_env("REF_PYTHON_BIN", "../cad_worker/.venv/bin/python")
  ],
  llm: [
    provider: String.to_atom(System.get_env("LLM_PROVIDER", "openai")),
    base_url: blank_to_nil.(System.get_env("LLM_BASE_URL", "https://api.z.ai/api/paas/v4")),
    api_key: {:system, "LLM_API_KEY"},
    text_model: System.get_env("LLM_TEXT_MODEL", "glm-5.3-flash"),
    vision_model: System.get_env("LLM_VISION_MODEL", "glm-4.6v"),
    timeout_s: String.to_integer(System.get_env("LLM_TIMEOUT_S", "600")),
    max_tokens: String.to_integer(System.get_env("LLM_MAX_TOKENS", "32768")),
    repair_max_elapsed_s: String.to_integer(System.get_env("REPAIR_MAX_ELAPSED_S", "240"))
  ]
