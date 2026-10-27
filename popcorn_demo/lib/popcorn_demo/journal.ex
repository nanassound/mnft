defmodule PopcornDemo.Journal do
  @moduledoc """
  In-browser stand-in for the mnft_cad journal storage (ETS-backed, fsynced
  on disk upstream). The ETS table is owned by this GenServer, NOT by a Task
  — a Task that creates a table dies immediately and takes the table with it
  (this exact bug crashed the first boot attempt: unhandled insert-on-missing
  table took the boot Task, and Popcorn surfaces that as "VM exited").
  """
  use GenServer

  def start_link(_arg), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @impl true
  def init(_state) do
    :ets.new(:mnft_journal, [:named_table, :public, read_concurrency: true])
    {:ok, %{}}
  end
end
