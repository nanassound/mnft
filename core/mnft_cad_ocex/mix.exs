defmodule MnftOcex.MixProject do
  use Mix.Project

  @version "0.1.0"

  def project do
    [
      app: :mnft_cad_ocex,
      version: @version,
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description:
        "Native OCEx engine pack for mnft_cad: executes the ocex JSON construction " <>
          "dialect in the BEAM via OCEx (Open CASCADE Technology) NIFs. Full STEP/STL fidelity.",
      name: "mnft_cad_ocex"
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp deps do
    [
      {:mnft_cad, path: "../mnft_cad"},
      {:ocex, "~> 0.4.0"},
      {:jason, "~> 1.2"}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]
end
