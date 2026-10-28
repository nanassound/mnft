defmodule MnftCadWeb.Application do
  @moduledoc """
  The reference app's supervision tree: telemetry, PubSub, endpoint.
  The mnft_cad core (store, Jido, limiter, turn supervisor) starts itself.
  """

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      MnftCadWeb.Telemetry,
      {Phoenix.PubSub, name: MnftCadWeb.PubSub},
      MnftCadWeb.Endpoint
    ]

    opts = [strategy: :one_for_one, name: MnftCadWeb.Supervisor]
    Supervisor.start_link(children, opts)
  end

  @impl true
  def config_change(changed, _new, removed) do
    MnftCadWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
