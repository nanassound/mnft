defmodule PopcornDemo.MixProject do
  use Mix.Project

  @version "0.1.0"

  def project do
    [
      app: :popcorn_demo,
      version: @version,
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {PopcornDemo.Application, []}
    ]
  end

  defp deps do
    [{:popcorn, "1.0.0"}]
  end
end
