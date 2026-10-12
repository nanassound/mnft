import Config

config :mnft_cad, Mnft.Cad.Jido, agent_pools: []

# Web app config
config :mnft_cad_web,
  generators: [timestamp_type: :utc_datetime]

config :mnft_cad_web, MnftCadWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: MnftCadWeb.ErrorHTML, json: MnftCadWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: MnftCadWeb.PubSub,
  live_view: [signing_salt: "mCADwebRef01"]

# Configure LiveView
config :phoenix_live_view,
  root_tag_attribute: "phx-r"

# esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  mnft_cad_web: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=. --alias:three=./vendor/three/three.module.js),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# tailwind (the version is required)
config :tailwind,
  version: "4.3.3",
  mnft_cad_web: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# LLM client: long timeouts tuned for reasoning models.
config :req_llm,
  receive_timeout: 600_000,
  thinking_timeout: 600_000,
  load_dotenv: true,
  redact_context: true,
  warn_unverified_models: false

config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

config :phoenix, :json_library, Jason

import_config "#{config_env()}.exs"
