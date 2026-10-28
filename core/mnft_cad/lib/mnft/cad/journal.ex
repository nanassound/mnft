defmodule Mnft.Cad.Journal do
  @moduledoc """
  Append-only JSONL journal — the durable half of the default store.

  One line per operation, fsynced at append time (never buffered until
  shutdown). The atomic unit is the whole turn: `record_turn` produces ONE
  line. On boot, a torn final line (crash mid-append) is truncated away —
  everything before it survives. When the file grows past `@compact_bytes`,
  `append/1` replies `:compact_needed` and the store (still inside its own
  serialized write path) calls `compact/1` with a consistent snapshot.

  Line shape: `%{"v" => 1, "op" => op, ...}` — replay order = file order.
  Ops: `create_session`, `set_title`, `record_turn`, and the snapshot-only
  `msg_add` / `model_add`.
  """

  use GenServer

  @version 1
  @compact_bytes 32 * 1024 * 1024

  # --- client API --------------------------------------------------------------

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "All valid operations, oldest first (from the state built at init)."
  @spec lines() :: [map()]
  def lines, do: GenServer.call(__MODULE__, :lines)

  @doc """
  Append one operation, fsync. Replies `:ok`, or `:compact_needed` when the
  caller should follow up with `compact/1` (from the same serialized write
  path, so the snapshot is consistent).
  """
  @spec append(map()) :: :ok | :compact_needed
  def append(op), do: GenServer.call(__MODULE__, {:append, op})

  @doc "Rewrite the journal from `ops` (a full, consistent snapshot)."
  @spec compact([map()]) :: :ok
  def compact(ops), do: GenServer.call(__MODULE__, {:compact, ops})

  # --- server ------------------------------------------------------------------

  @impl true
  def init(opts) do
    path = Keyword.fetch!(opts, :path)
    File.mkdir_p!(Path.dirname(path))

    {ops, size} = read_all(path)
    {:ok, io} = :file.open(path, [:append, :raw])

    {:ok, %{path: path, io: io, size: size, ops: ops}}
  end

  # Reads the journal; a torn trailing line (crash mid-append) is truncated
  # away on disk and dropped.
  defp read_all(path) do
    case File.read(path) do
      {:ok, data} when data != "" ->
        retained = drop_torn_tail(data)

        if retained != data do
          File.write!(path, retained)
        end

        ops = retained |> String.split("\n", trim: true) |> decode_lines([])
        {ops, byte_size(retained)}

      _ ->
        {[], 0}
    end
  end

  defp drop_torn_tail(data) do
    if String.ends_with?(data, "\n") do
      data
    else
      case String.split(data, "\n") do
        [_only] -> ""
        parts -> (parts |> Enum.drop(-1) |> Enum.join("\n")) <> "\n"
      end
    end
  end

  defp decode_lines([], acc), do: Enum.reverse(acc)

  defp decode_lines([line | rest], acc) do
    case Jason.decode(line) do
      {:ok, map} -> decode_lines(rest, [map | acc])
      _ -> decode_lines(rest, acc)
    end
  end

  defp encode_line(op), do: op |> Map.put_new("v", @version) |> Jason.encode!() |> Kernel.<>("\n")

  @impl true
  def handle_call(:lines, _from, %{ops: ops} = state), do: {:reply, ops, state}

  def handle_call({:append, op}, _from, state) do
    line = encode_line(op)
    :ok = :file.write(state.io, line)
    state = %{state | size: state.size + byte_size(line), ops: state.ops ++ [op]}

    if state.size > @compact_bytes do
      {:reply, :compact_needed, state}
    else
      {:reply, :ok, state}
    end
  end

  def handle_call({:compact, ops}, _from, %{path: path, io: io} = state) do
    tmp = path <> ".compact"
    data = ops |> Enum.map(&encode_line/1) |> Enum.join("")
    File.write!(tmp, data)
    File.rename!(tmp, path)
    _ = :file.close(io)
    {:ok, new_io} = :file.open(path, [:append, :raw])

    {:reply, :ok, %{state | io: new_io, ops: ops, size: byte_size(data)}}
  end
end
