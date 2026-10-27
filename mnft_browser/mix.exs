defmodule MnftBrowser.MixProject do
  use Mix.Project

  @version "0.1.0"

  def project do
    [
      app: :mnft_browser,
      version: @version,
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {MnftBrowser.Application, []}
    ]
  end

  defp deps do
    [
      {:mnft_cad, path: "../mnft_cad"},
      {:popcorn, "1.0.0"}
    ]
  end

  # The host-side assets (replicad worker, three.js) are built from their
  # packages first, then Popcorn packages/serves the app.
  defp aliases do
    [
      dev: ["host.assets", "popcorn.dev"],
      cook: ["host.assets", "popcorn.cook"]
    ]
  end
end
