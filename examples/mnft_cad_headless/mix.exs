defmodule MnftCadHeadless.MixProject do
  use Mix.Project

  @version "0.1.0"

  def project do
    [
      app: :mnft_cad_headless,
      version: @version,
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      name: "mnft_cad_headless"
    ]
  end

  # No `mod`: depending on :mnft_cad is enough — its application callback
  # starts the whole core supervision tree (ETS store + journal replay,
  # Jido instance, ExecLimiter, TurnSupervisor) before this app's code runs.
  def application do
    [extra_applications: [:logger]]
  end

  defp deps do
    [
      {:mnft_cad, path: "../../core/mnft_cad"}
    ]
  end
end
