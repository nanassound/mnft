# syntax=docker/dockerfile:1
# mnft — one image for trying and deploying. A `mix release` build of the
# reference app (mnft_cad_web) plus the guarded build123d worker and poppler;
# nothing else is needed on the host.
#
#   docker build -t mnft .
#   docker run --rm -p 4000:4000 -e LLM_API_KEY=sk-... mnft
#   open http://localhost:4000
#
# Generated models and the journal live in /data; add `-v mnft-data:/data` to
# keep them across runs.
#
# For a long-lived deployment also set SECRET_KEY_BASE — without it a random
# key is generated per boot and saved parts become unreachable after a
# restart — and PHX_HOST when the app sits behind a proxy. The caution at the
# end of the README applies: the worker is guarded, not a sandbox.

ARG ELIXIR_BASE=hexpm/elixir:1.18.5-erlang-27.3.4.18-debian-bookworm-20261005

FROM ${ELIXIR_BASE} AS builder
ENV MIX_ENV=prod
WORKDIR /build
RUN apt-get update \
 && apt-get install -y --no-install-recommends build-essential git ca-certificates curl \
 && rm -rf /var/lib/apt/lists/*
RUN mix local.hex --force && mix local.rebar --force

# Preserve the repo's relative layout: mnft_cad_web's mix.exs declares
# {:mnft_cad, path: "../../core/mnft_cad"}.
COPY core/mnft_cad/mix.exs core/mnft_cad/mix.lock core/mnft_cad/
COPY examples/mnft_cad_web/mix.exs examples/mnft_cad_web/mix.lock examples/mnft_cad_web/
WORKDIR /build/examples/mnft_cad_web
RUN mix deps.get --only prod

WORKDIR /build
COPY core/mnft_cad/config core/mnft_cad/config
COPY core/mnft_cad/lib core/mnft_cad/lib
COPY core/mnft_cad/priv core/mnft_cad/priv
COPY examples/mnft_cad_web/config examples/mnft_cad_web/config
COPY examples/mnft_cad_web/priv examples/mnft_cad_web/priv
COPY examples/mnft_cad_web/assets examples/mnft_cad_web/assets
COPY examples/mnft_cad_web/lib examples/mnft_cad_web/lib

WORKDIR /build/examples/mnft_cad_web
# esbuild/tailwind download their own platform binaries (no node). Order
# matters: mix compile must run first so the LiveView colocated-CSS compiler
# output exists before tailwind/esbuild resolve their sources.
RUN mix tailwind.install --if-missing \
 && mix esbuild.install --if-missing \
 && mix compile \
 && mix assets.build
RUN mix release --overwrite

# cad_worker venv: uv-managed standalone CPython 3.12 (bookworm apt only has
# 3.11; pyproject requires <3.13). ghcr.io pulls can be unavailable or
# rate-limited, hence the astral.sh standalone installer rather than a uv image.
RUN curl -LsSf https://astral.sh/uv/install.sh | sh \
 && cp /root/.local/bin/uv /usr/local/bin/uv
COPY core/cad_worker /build/cad_worker
ENV UV_PYTHON_INSTALL_DIR=/opt/python
RUN uv python install 3.12 \
 && uv venv /opt/venv --python 3.12 \
 && VIRTUAL_ENV=/opt/venv uv pip install "/build/cad_worker[smlibpy]"

FROM debian:bookworm-slim AS runtime
ENV LC_ALL=C.UTF-8
# libgl1/libglu1-mesa/libxi6/libxrender1: OpenCascade runtime libs build123d
# needs. poppler-utils: pdftoppm/pdftotext for the PDF datasheet reference
# stage. libssl3 + ca-certificates: ERTS crypto NIF and the LLM HTTPS trust
# store. curl: container healthchecks.
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      libssl3 ca-certificates curl libgl1 libglu1-mesa libxi6 libxrender1 \
      poppler-utils \
 && rm -rf /var/lib/apt/lists/* \
 && groupadd -g 10001 app && useradd -u 10001 -g 10001 -m -s /usr/sbin/nologin app
WORKDIR /app
COPY --from=builder /build/examples/mnft_cad_web/_build/prod/rel/mnft_cad_web/ ./
COPY --from=builder /opt/python /opt/python
COPY --from=builder /opt/venv /opt/venv
COPY core/cad_worker /app/cad_worker
RUN mkdir -p /data/models && chown -R app:app /data /app
USER app
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1 \
    CAD_WORKER_PYTHON=/opt/venv/bin/python \
    CAD_WORKER_CWD=/app/cad_worker \
    CAD_MODELS_DIR=/data/models \
    MNFT_DATA_DIR=/data
EXPOSE 4000
CMD ["/app/bin/mnft_cad_web", "start"]
