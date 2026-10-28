defmodule MnftCadWeb.MixProject do
  use Mix.Project

  @version "0.1.0"

  def project do
    [
      app: :mnft_cad_web,
      version: @version,
      elixir: "~> 1.17",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      listeners: [Phoenix.CodeReloader],
      name: "mnft_cad_web"
    ]
  end

  def application do
    [
      mod: {MnftCadWeb.Application, []},
      extra_applications: [:logger, :runtime_tools, :crypto]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:mnft_cad, path: "../../core/mnft_cad"},
      {:phoenix, "~> 1.8.15"},
      {:phoenix_live_view, "~> 1.2"},
      {:phoenix_html, "~> 4.1"},
      {:gettext, "~> 0.26"},
      {:heroicons,
       github: "tailwindlabs/heroicons",
       tag: "v2.2.0",
       sparse: "optimized",
       app: false,
       compile: false,
       depth: 1},
      {:jason, "~> 1.2"},
      {:bandit, "~> 1.5"},
      {:phoenix_live_reload, "~> 1.5", only: :dev},
      {:lazy_html, ">= 0.1.0", only: :test},
      {:telemetry, "~> 1.2"},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.1"},
      {:esbuild, "~> 0.10", runtime: Mix.env() == :dev},
      {:tailwind, "~> 0.3", runtime: Mix.env() == :dev}
    ]
  end

  defp aliases do
    [
      setup: ["deps.get", "assets.build"],
      "assets.build": ["tailwind mnft_cad_web", "esbuild mnft_cad_web"],
      "assets.watch": [
        "tailwind mnft_cad_web --watch",
        "esbuild mnft_cad_web --sourcemap=inline --watch"
      ]
    ]
  end
end
