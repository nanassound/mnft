defmodule Mnft.Cad.ExecLimiter do
  @moduledoc """
  A FIFO counting-semaphore GenServer capping simultaneous harness executions
  (the Elixir-side replacement for the PoC's `threading.Semaphore(EXEC_CONCURRENCY)`).

  `run/2` checks out a permit, runs the function, and checks the permit back
  in -- including on raise/exit. Waiters are monitored so a crashed caller
  never leaks its queue slot.
  """

  use GenServer

  @doc """
  Execute `fun` while holding one of `capacity` permits. Blocks (FIFO) when
  the pool is saturated. Returns whatever `fun` returns.
  """
  def run(server \\ __MODULE__, fun) when is_function(fun, 0) do
    :ok = GenServer.call(server, :checkout, :infinity)

    try do
      fun.()
    after
      GenServer.cast(server, :checkin)
    end
  end

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(opts) do
    capacity = Keyword.fetch!(opts, :capacity)
    {:ok, %{free: capacity, queue: :queue.new()}}
  end

  @impl true
  def handle_call(:checkout, _from, %{free: free} = state) when free > 0 do
    {:reply, :ok, %{state | free: free - 1}}
  end

  def handle_call(:checkout, {caller, _ref} = from, state) do
    ref = Process.monitor(caller)
    queue = :queue.in({from, ref}, state.queue)
    {:noreply, %{state | queue: queue}}
  end

  @impl true
  def handle_cast(:checkin, state), do: {:noreply, grant(state)}

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    queue = :queue.filter(fn {_from, mref} -> mref != ref end, state.queue)
    {:noreply, %{state | queue: queue}}
  end

  # A released permit passes straight to the next live waiter (transfer);
  # with no waiter it returns to the pool.
  defp grant(%{queue: queue} = state) do
    case :queue.out(queue) do
      {{:value, {from, ref}}, rest} ->
        if Process.alive?(elem(from, 0)) do
          Process.demonitor(ref, [:flush])
          GenServer.reply(from, :ok)
          %{state | queue: rest}
        else
          grant(%{state | queue: rest})
        end

      {:empty, _queue} ->
        %{state | free: state.free + 1}
    end
  end
end
