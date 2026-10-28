import Config

config :logger, :default_formatter, format: "[$level] $message\n"

# Popcorn: the :crypto NIF runtime variant (strong_rand_bytes for model ids).
config :popcorn, runtime_variant: :crypto

# Long LLM timeouts for BYOK turns over the browser fetch adapter; no .env
# loading (keys arrive from the page's settings panel, never the filesystem).
config :req_llm,
  receive_timeout: 600_000,
  thinking_timeout: 600_000,
  load_dotenv: false,
  redact_context: true,
  warn_unverified_models: false

# Jido instance (per-session turn agents) — no pools under WASM.
config :mnft_cad, Mnft.Cad.Jido, agent_pools: []

# Embed the model catalog into the beam at compile time: under Popcorn there
# is no filesystem, and llm_db's default runtime read of
# priv/llm_db/snapshot.json fails, falling back to an EMPTY catalog (every
# BYOK model id then dies in req_llm's catalog-gateway contract check).
config :llm_db, compile_embed: true

# The whole core, wired for the browser: ETS-only store with the journal
# OFF (no filesystem under WASM), the replicad engine (page-side worker),
# the scripted LLM by default (BYOK swaps :llm_module at runtime), and
# events bridged to the page over Popcorn.JS.
config :mnft_cad, :cad,
  store: Mnft.Cad.Store.Ets,
  journal: false,
  engine: MnftBrowser.Engines.Replicad,
  llm_module: Mnft.Cad.LLMFake,
  events: {MnftBrowser.Events, :to_page, []},
  exec_concurrency: 1,
  exec_timeout_s: 60
