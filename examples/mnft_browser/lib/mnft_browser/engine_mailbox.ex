defmodule MnftBrowser.EngineMailbox do
  @moduledoc """
  Receives worker results from the page and forwards them to the waiting
  engine caller.

  The page targets the REGISTERED NAME (`popcorn.send("mnft_engine_mailbox",
  …)`): a name target is plain string routing, while run!-arg pid round-trips
  are not accepted as send targets. The run id routes each message to the
  right caller; `execute/2` registers itself (`expect/1`) before dispatching
  the run, so the registration always precedes any result.
  """

  use GenServer

  @name :mnft_engine_mailbox

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: @name)

  @doc "Register this caller as the receiver of run `model_id`'s result."
  @spec expect(String.t()) :: :ok
  def expect(model_id), do: GenServer.call(@name, {:expect, model_id})

  @doc """
  Wait for run `model_id`. The mailbox forwards the page's payload raw:
  `{:engine_result, model_id, result_map}` (JS keys arrive as binaries).
  """
  @spec await(String.t(), non_neg_integer()) :: {:ok, map()} | :timeout
  def await(model_id, timeout) do
    receive do
      {:engine_result, ^model_id, res} -> {:ok, res}
    after
      timeout -> :timeout
    end
  end

  @impl true
  def init(_opts), do: {:ok, %{}}

  @impl true
  def handle_call({:expect, model_id}, {caller, _ref}, state) do
    {:reply, :ok, Map.put(state, model_id, caller)}
  end

  # popcorn.send delivers {:wasm, payload} raw to this registered process.
  @impl true
  def handle_info({:wasm, ["engine_result", model_id, res]}, state) do
    case Map.pop(state, model_id) do
      {nil, state} ->
        {:noreply, state}

      {caller, state} ->
        send(caller, {:engine_result, model_id, res})
        {:noreply, state}
    end
  end

  def handle_info({:wasm, _other}, state), do: {:noreply, state}
end
