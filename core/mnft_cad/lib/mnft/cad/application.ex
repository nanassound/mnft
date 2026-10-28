defmodule Mnft.Cad.Application do
  @moduledoc """
  The core's supervision tree. Embedding apps get it automatically by
  depending on `:mnft_cad` (the application starts itself), or explicitly via
  `Mnft.Cad.Application.start/2` when embedding as a library.

  Children: the default store (ETS tables + journal replay), the Jido
  instance (one agent per session), the execution limiter (build pool), and
  the turn task supervisor. A crashed turn task never takes any of these
  down; a crashed LiveView never touches them.
  """

  use Application

  @impl true
  def start(_type, _args) do
    cfg = Mnft.Cad.Config.all()

    # the default ETS store is only started when it is the selected adapter
    default_store? = cfg[:store] in [nil, Mnft.Cad.Store.Ets]

    children =
      if default_store? do
        [{Mnft.Cad.Store.Ets, cfg} | base_children(cfg)]
      else
        base_children(cfg)
      end

    Supervisor.start_link(children, strategy: :one_for_one, name: Mnft.Cad.Supervisor)
  end

  defp base_children(cfg) do
    [
      Mnft.Cad.PhotoCache,
      Mnft.Cad.Jido,
      {Mnft.Cad.ExecLimiter, [capacity: cfg[:exec_concurrency] || 2]},
      {Task.Supervisor, name: Mnft.Cad.TurnSupervisor}
    ]
  end
end
