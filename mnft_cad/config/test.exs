import Config

config :logger, level: :warning

# Core pipeline under test: fake seams, tmp dirs, default ETS store.
config :mnft_cad, :cad,
  models_dir: System.tmp_dir!() |> Path.join("mnft-cad-test-models"),
  data_dir: System.tmp_dir!() |> Path.join("mnft-cad-test-data"),
  exec_concurrency: 2,
  exec_timeout_s: 60,
  turn_budget_s: 900,
  llm_module: Mnft.Cad.LLMFake,
  engine: Mnft.Cad.EngineFake,
  references_module: Mnft.Cad.ReferencesFake,
  events: {Mnft.Cad.TestEvents, :emit, []},
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
