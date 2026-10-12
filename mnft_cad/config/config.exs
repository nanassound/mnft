import Config

# Jido instance (per-session turn agents)
config :mnft_cad, Mnft.Cad.Jido, agent_pools: []

# LLM client: long timeouts tuned for reasoning models (glm-5.3-flash can
# legitimately think for 200-300 s on datasheet-class parts). Payloads are
# redacted from inspect/logs; photos must never leak through logging.
config :req_llm,
  receive_timeout: 600_000,
  thinking_timeout: 600_000,
  load_dotenv: true,
  redact_context: true,
  warn_unverified_models: false

config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

import_config "#{config_env()}.exs"
