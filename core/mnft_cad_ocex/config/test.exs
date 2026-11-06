import Config

config :logger, level: :warning

# The core boots its supervision tree as a dependency application; this config
# gives it tmp dirs and the OCEx engine. `worker_*` point at the core repo's
# cad_worker venv for the cross-kernel agreement test only.
config :mnft_cad, :cad,
  store: Mnft.Cad.Store.Ets,
  journal: false,
  engine: MnftOcex.Engine,
  llm_module: Mnft.Cad.LLMFake,
  models_dir: System.tmp_dir!() |> Path.join("mnft-ocex-test-models"),
  data_dir: System.tmp_dir!() |> Path.join("mnft-ocex-test-data"),
  exec_concurrency: 2,
  exec_timeout_s: 60,
  turn_budget_s: 900,
  worker_python: Path.expand("../../cad_worker/.venv/bin/python", __DIR__),
  worker_cwd: Path.expand("../../cad_worker", __DIR__)
