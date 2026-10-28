defmodule Mnft.Cad.MixProject do
  use Mix.Project

  @version "0.1.0"

  def project do
    [
      app: :mnft_cad,
      version: @version,
      elixir: "~> 1.17",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description:
        "Open core for LLM chat-to-CAD modelling on the BEAM: turn pipeline, " <>
          "pluggable engines (build123d, OpenSCAD), pluggable storage, BYO-key multi-provider LLM.",
      package: package(),
      name: "mnft_cad"
    ]
  end

  def application do
    [
      mod: {Mnft.Cad.Application, []},
      extra_applications: [:logger, :runtime_tools, :crypto]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:jido, "~> 2.4"},
      {:req_llm, "~> 1.27"},
      {:req, "~> 0.7"},
      {:jason, "~> 1.2"},
      {:telemetry, "~> 1.2"}
    ]
  end

  defp package do
    [
      licenses: ["Apache-2.0"],
      links: %{},
      files: ~w(lib priv config mix.exs README.md LICENSE)
    ]
  end
end
