import Config

config :logger, level: :warning

# Core pipeline under test: fake seams, tmp dirs, default ETS store.
config :mnft_cad, :cad,
  events: {MnftCadWeb.PubSubBridge, :emit_as_handler, []},
  models_dir: System.tmp_dir!() |> Path.join("mnft-cad-web-test-models"),
  data_dir: System.tmp_dir!() |> Path.join("mnft-cad-web-test-data"),
  exec_concurrency: 2,
  exec_timeout_s: 60,
  turn_budget_s: 900,
  cam: [
    freecad_cmd: "/nonexistent/freecad",
    timeout_s: 5
  ],
  llm_module: Mnft.Cad.LLMFake,
  engine: Mnft.Cad.EngineFake,
  llm: [
    base_url: "https://example.test/v4",
    api_key: "test-key",
    provider: :openai,
    text_model: "test-text",
    vision_model: "test-vision",
    timeout_s: 1,
    max_tokens: 1024,
    repair_max_elapsed_s: 240
  ]

config :mnft_cad_web, MnftCadWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4200],
  server: false,
  secret_key_base: "tHPElH8SHheLkjbvWLQhHXvBTRDGvLNzJhdvXhhwEpEvcTnYLBokmLkOnKdvYsDz"

config :phoenix, :plug_init_mode, :runtime
