defmodule PopcornDemo.Application do
  @moduledoc """
  Popcorn spike for mnft: proves the mnft_cad shape (pure Elixir/OTP core,
  supervision tree, ETS-backed state) can boot inside the browser on the
  real BEAM-in-WASM runtime.
  """
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      # ETS-backed journal stand-in, owned by a long-lived GenServer.
      {PopcornDemo.Journal, []},
      # Boot banner task — touches the DOM from Elixir once JS is ready.
      {Task, &PopcornDemo.set_html/0}
    ]

    opts = [strategy: :one_for_one, name: PopcornDemo.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
