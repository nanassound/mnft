# mnft reference web app (mnft_cad_web) with the build123d worker and poppler.
#
#   docker build -t mnft .
#   docker run --rm -p 4200:4200 -e LLM_API_KEY=sk-... mnft
#   open http://localhost:4200
#
# Other settings from .env.example can be passed with -e or --env-file.
# Generated models and the journal live in /app/mnft_cad_web/data; mount a
# volume there to keep them: -v mnft-data:/app/mnft_cad_web/data
#
# The app runs in its dev config (the repo ships no prod config), so this
# image is for trying mnft locally, not for exposing to the internet.

FROM elixir:1.18-otp-27

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      git poppler-utils libgl1 libglib2.0-0 \
 && rm -rf /var/lib/apt/lists/*

COPY --from=ghcr.io/astral-sh/uv:latest /uv /usr/local/bin/uv

WORKDIR /app

# Python worker (build123d). Dependencies first for layer caching.
COPY cad_worker/pyproject.toml cad_worker/pyproject.toml
COPY cad_worker/cad_worker cad_worker/cad_worker
RUN cd cad_worker \
 && uv venv --python 3.12 \
 && uv pip install .

# Elixir deps, then sources.
RUN mix local.hex --force && mix local.rebar --force
COPY mnft_cad/mix.exs mnft_cad/mix.lock mnft_cad/
COPY mnft_cad_web/mix.exs mnft_cad_web/mix.lock mnft_cad_web/
COPY mnft_cad_web/config mnft_cad_web/config
COPY mnft_cad/config mnft_cad/config
RUN cd mnft_cad_web && mix deps.get

COPY mnft_cad mnft_cad
COPY mnft_cad_web mnft_cad_web
RUN cd mnft_cad_web \
 && mix compile \
 && mix tailwind.install --if-missing \
 && mix esbuild.install --if-missing \
 && mix assets.build

ENV MNFT_DOCKER=1 \
    MIX_ENV=dev

WORKDIR /app/mnft_cad_web
EXPOSE 4200
CMD ["mix", "phx.server"]
