defmodule Mnft.Cad.PhotoCache do
  @table :mnft_photo_cache
  @index :mnft_photo_cache_index
  @max_sessions 128
  @max_total_bytes 192 * 1024 * 1024

  @moduledoc """
  In-memory, one-generation-deep carry-forward of each session's most recent
  image set.

  Chat photos used to live exactly one turn: a follow-up like "make it 126HP"
  reached the LLM with no images, so "it" was ungrounded. `put/2` records a
  session's latest image set when a turn ends; `take/1` lets a photo-less turn
  re-send the previous set (labeled "earlier"). This is the only place image
  bytes outlive a turn process — server memory only, never written to disk,
  the model store, the journal, or logs (see `Mnft.Cad.Images`).

  Bounds: at most #{@max_sessions} sessions and #{@max_total_bytes} bytes of
  image data; the oldest-touched sessions are evicted first. A photo-less turn
  never overwrites the cached set, and `clear/1` drops it on demand.
  """

  use GenServer

  def start_link(_opts), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  @doc """
  Remember `images` as the session's most recent set. An empty set never
  overwrites an existing row, so "most recent photos in session" survive
  photo-less turns until new photos arrive.
  """
  @spec put(String.t(), [map()]) :: :ok
  def put(_session_id, []), do: :ok

  def put(session_id, images) when is_list(images) do
    if tables_up?(), do: GenServer.call(__MODULE__, {:put, session_id, images}), else: :ok
  end

  @doc "The session's most recent image set (`[]` when none). Read-only."
  @spec take(String.t()) :: [map()]
  def take(session_id) do
    if tables_up?() do
      case :ets.lookup(@table, session_id) do
        [{^session_id, %{images: images}}] -> images
        _ -> []
      end
    else
      []
    end
  end

  @doc "Forget a session's cached images."
  @spec clear(String.t()) :: :ok
  def clear(session_id) do
    if tables_up?(), do: GenServer.call(__MODULE__, {:clear, session_id}), else: :ok
  end

  # --- server -----------------------------------------------------------------

  # Named public tables so read paths skip the GenServer. Content lives only
  # while this process does — a restart rebuilds empty tables by design.
  @impl true
  def init([]) do
    :ets.new(@table, [:set, :named_table, :public, read_concurrency: true])
    :ets.new(@index, [:set, :named_table, :public])
    {:ok, nil}
  end

  @impl true
  def handle_call({:put, session_id, images}, _from, state) do
    touched = :erlang.unique_integer([:monotonic])
    size = Enum.sum(Enum.map(images, &byte_size(Map.get(&1, :bytes, ""))))

    :ets.insert(@table, {session_id, %{images: images, size: size, touched_at: touched}})
    :ets.match_delete(@index, {{:idx, session_id}, :_})
    :ets.insert(@index, {{:idx, session_id}, {touched, size}})

    evict_over_limit()
    {:reply, :ok, state}
  end

  def handle_call({:clear, session_id}, _from, state) do
    :ets.delete(@table, session_id)
    :ets.match_delete(@index, {{:idx, session_id}, :_})
    {:reply, :ok, state}
  end

  # Walk oldest-first over the small index table (no image payloads copied)
  # until both caps hold again.
  defp evict_over_limit do
    entries = :ets.tab2list(@index)

    if length(entries) > @max_sessions or
         Enum.sum(Enum.map(entries, fn {_, {_, size}} -> size end)) > @max_total_bytes do
      entries
      |> Enum.sort_by(fn {_, {touched, _}} -> touched end)
      |> Enum.reduce_while({length(entries), total_bytes(entries)}, fn
        {{:idx, session_id}, {_, size}}, {n, total} when n > @max_sessions or total > @max_total_bytes ->
          :ets.delete(@table, session_id)
          :ets.delete(@index, {:idx, session_id})
          {:cont, {n - 1, total - size}}

        _entry, acc ->
          {:halt, acc}
      end)
    end

    :ok
  end

  defp total_bytes(entries), do: Enum.sum(Enum.map(entries, fn {_, {_, size}} -> size end))

  defp tables_up? do
    :ets.whereis(@table) != :undefined and :ets.whereis(@index) != :undefined
  end
end
