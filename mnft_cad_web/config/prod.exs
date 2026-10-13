import Config

# Minimal prod config: config.exs already carries everything the reference app
# needs (endpoint basics, esbuild/tailwind, req_llm timeouts, logger). The
# DB-less core defaults to its ETS store backed by a JSONL journal, so there is
# no database config. Runtime settings (port, host, secret key, the full
# `config :mnft_cad, :cad` pipeline block and the LiveView events bridge) are
# applied in runtime.exs so every deploy-relevant value stays env-driven.
