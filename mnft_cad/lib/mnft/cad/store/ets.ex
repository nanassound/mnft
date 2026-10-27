defmodule Mnft.Cad.Store.Ets do
  @moduledoc """
  The default store: ETS for reads, an fsynced JSONL journal
  (`Mnft.Cad.Journal`) for durability. Zero dependencies, no external
  services; the data dir is just a path (`:data_dir` config, default
  `"data"`; journal at `<data_dir>/mnft_cad.jsonl`).

  Write path (serialized through this GenServer, journal first so the disk
  is authoritative): append one journal line (one per turn), fsync, then
  apply to ETS. Boot: replay the journal into fresh tables. A crash loses at
  most the turn being appended (its torn line is truncated at boot); ETS is
  always rebuildable. Compaction rewrites the journal from a snapshot taken
  inside the same serialized write path.

  Model artifact FILES are never here — they are files under `:models_dir`;
  the journal stores metadata only.

  Embedders that keep state fully in memory (e.g. the browser bundle, where
  there is no writable filesystem) set `config :mnft_cad, :cad, journal: false`:
  no `Mnft.Cad.Journal` process is started, nothing is appended, and boot does
  no replay. The default (key unset) keeps the journal-first durability above.
  """

  @behaviour Mnft.Cad.Store
  use GenServer

  alias Mnft.Cad.Journal
  alias Mnft.Cad.{Message, Model, Session}

  # --- lifecycle ---------------------------------------------------------------

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(cfg) do
    Enum.each(table_specs(), fn {name, type} ->
      :ets.new(name, [type, :named_table, :public, read_concurrency: true])
    end)

    journal? = cfg[:journal] != false

    if journal? do
      path = journal_path(cfg)

      {:ok, _} = Journal.start_link(path: path)

      Journal.lines() |> Enum.each(&apply_op/1)
    end

    {:ok, %{journal: journal?}}
  end

  defp journal_path(cfg), do: Path.join(cfg[:data_dir] || "data", "mnft_cad.jsonl")

  defp table_specs do
    [
      {:mnft_sessions, :set},
      {:mnft_sessions_by_owner, :ordered_set},
      {:mnft_messages, :ordered_set},
      {:mnft_counters, :set},
      {:mnft_models, :set},
      {:mnft_models_by_session, :ordered_set}
    ]
  end

  # --- Store behaviour (reads: direct ETS) ---------------------------------------

  @impl Mnft.Cad.Store
  def list_sessions(owner_id) do
    :mnft_sessions_by_owner
    |> :ets.match_object({{owner_id, :_, :_}, :_})
    |> Enum.map(fn {_key, id} -> session!(id) end)
  end

  @impl Mnft.Cad.Store
  def get_session(owner_id, session_id) do
    case lookup_session(session_id) do
      %{owner_id: ^owner_id} = session -> {:ok, session}
      _ -> {:error, :not_found}
    end
  end

  @impl Mnft.Cad.Store
  def list_messages(session_id) do
    :mnft_messages
    |> :ets.match_object({{session_id, :_}, :_})
    |> Enum.map(fn {_key, message} -> message end)
  end

  @impl Mnft.Cad.Store
  def latest_model(session_id) do
    # keys are {session_id, -ts, id}: ascending traversal puts the newest first
    :mnft_models_by_session
    |> :ets.match_object({{session_id, :_, :_}, :_})
    |> Enum.map(fn {_key, id} -> model!(id) end)
    |> List.first()
  end

  @impl Mnft.Cad.Store
  def get_model(owner_id, model_id) do
    case lookup_model(model_id) do
      %{owner_id: ^owner_id} = model -> model
      _ -> nil
    end
  end

  # --- Store behaviour (writes: serialized, journal first) ------------------------

  @impl Mnft.Cad.Store
  def create_session(owner_id, attrs \\ %{}) do
    GenServer.call(__MODULE__, {:create_session, owner_id, attrs})
  end

  @impl Mnft.Cad.Store
  def set_title_if_blank(session, text) do
    GenServer.call(__MODULE__, {:set_title_if_blank, session, text})
  end

  @impl Mnft.Cad.Store
  def record_turn(session, user_attrs, assistant_attrs, model_attrs) do
    GenServer.call(__MODULE__, {:record_turn, session, user_attrs, assistant_attrs, model_attrs})
  end

  # --- server ------------------------------------------------------------------

  @impl true
  def handle_call({:create_session, owner_id, attrs}, _from, state) do
    now = now()

    session = %Session{
      id: new_id(),
      owner_id: owner_id,
      title: attrs[:title] || "",
      inserted_at: now,
      updated_at: now
    }

    op = %{"op" => "create_session", "session" => session_map(session)}

    append_or_compact!(state, op)
    apply_op(op)
    {:reply, {:ok, session}, state}
  end

  def handle_call({:set_title_if_blank, session, text}, _from, state) do
    if session.title == "" do
      title =
        text
        |> String.trim()
        |> String.slice(0, 60)
        |> case do
          "" -> "New part"
          t -> t
        end

      op = %{"op" => "set_title", "session_id" => session.id, "title" => title}
      append_or_compact!(state, op)
      apply_op(op)

      {:reply, {:ok, %{session | title: title, updated_at: now()}}, state}
    else
      {:reply, {:ok, :titled}, state}
    end
  end

  def handle_call({:record_turn, session, user_attrs, assistant_attrs, model_attrs}, _from, state) do
    ts = now()
    seq_base = next_seq(session.id, 2)

    user_message = %Message{
      id: new_id(),
      session_id: session.id,
      role: :user,
      content: user_attrs.content,
      meta: user_attrs.meta || %{},
      seq: seq_base,
      inserted_at: ts,
      updated_at: ts
    }

    assistant_message = %Message{
      id: new_id(),
      session_id: session.id,
      role: :assistant,
      content: assistant_attrs.content,
      code: assistant_attrs[:code],
      meta: assistant_attrs.meta || %{},
      seq: seq_base + 1,
      inserted_at: ts,
      updated_at: ts
    }

    model =
      if model_attrs do
        %Model{
          id: model_attrs.id,
          session_id: session.id,
          owner_id: session.owner_id,
          mesh: model_attrs.mesh || %{},
          has_glb: !!model_attrs.has_glb,
          inserted_at: ts,
          updated_at: ts
        }
      end

    op = %{
      "op" => "record_turn",
      "session_id" => session.id,
      "user" => message_map(user_message),
      "assistant" => message_map(assistant_message),
      "model" => (model && model_map(model)) || nil
    }

    append_or_compact!(state, op)
    apply_op(op)

    {:reply,
     {:ok, %{user_message: user_message, assistant_message: assistant_message, model: model}},
     state}
  end

  # Journal-first, then ETS. If the journal asks for compaction, snapshot from
  # the PRE-apply state (this op is not yet in ETS) and then apply.
  # With `journal: false` the write path stops after ETS — nothing touches
  # `Mnft.Cad.Journal` (this is the single journal chokepoint for all writes).
  defp append_or_compact!(%{journal: false}, _op), do: :ok

  defp append_or_compact!(_state, op) do
    case Journal.append(op) do
      :ok -> :ok
      :compact_needed -> Journal.compact(pre_state_ops() ++ [op])
    end
  end

  defp pre_state_ops() do
    sessions =
      :mnft_sessions
      |> :ets.tab2list()
      |> Enum.map(fn {_id, s} -> %{"op" => "create_session", "session" => session_map(s)} end)

    messages =
      :mnft_messages
      |> :ets.tab2list()
      |> Enum.map(fn {_key, m} -> %{"op" => "msg_add", "message" => message_map(m)} end)

    models =
      :mnft_models
      |> :ets.tab2list()
      |> Enum.map(fn {_id, m} -> %{"op" => "model_add", "model" => model_map(m)} end)

    sessions ++ messages ++ models
  end

  # --- replay ------------------------------------------------------------------

  defp apply_op(%{"op" => "create_session", "session" => map}) do
    session = struct_from_map(Session, map)
    :ets.insert(:mnft_sessions, {session.id, session})
    :ets.insert(:mnft_sessions_by_owner, {owner_key(session), session.id})
  end

  defp apply_op(%{"op" => "set_title", "session_id" => sid, "title" => title}) do
    case lookup_session(sid) do
      nil ->
        :ok

      session ->
        updated = %{session | title: title}
        :ets.insert(:mnft_sessions, {sid, updated})
    end
  end

  defp apply_op(%{
         "op" => "record_turn",
         "user" => user,
         "assistant" => assistant,
         "model" => model
       }) do
    user_m = struct_from_map(Message, user)
    assistant_m = struct_from_map(Message, assistant)
    :ets.insert(:mnft_messages, {{user_m.session_id, user_m.seq}, user_m})
    :ets.insert(:mnft_messages, {{assistant_m.session_id, assistant_m.seq}, assistant_m})
    bump_seq(user_m.session_id, assistant_m.seq)

    if model do
      model_m = struct_from_map(Model, model)
      :ets.insert(:mnft_models, {model_m.id, model_m})
      :ets.insert(:mnft_models_by_session, {model_key(model_m), model_m.id})
    end
  end

  defp apply_op(%{"op" => "msg_add", "message" => map}) do
    m = struct_from_map(Message, map)
    :ets.insert(:mnft_messages, {{m.session_id, m.seq}, m})
    bump_seq(m.session_id, m.seq)
  end

  defp apply_op(%{"op" => "model_add", "model" => map}) do
    m = struct_from_map(Model, map)
    :ets.insert(:mnft_models, {m.id, m})
    :ets.insert(:mnft_models_by_session, {model_key(m), m.id})
  end

  # --- helpers -----------------------------------------------------------------

  defp lookup_session(id) do
    case :ets.lookup(:mnft_sessions, id) do
      [{^id, session}] -> session
      [] -> nil
    end
  end

  defp session!(id) do
    case lookup_session(id) do
      nil -> raise "journal/ETS inconsistency: session #{id} missing"
      session -> session
    end
  end

  defp lookup_model(id) do
    case :ets.lookup(:mnft_models, id) do
      [{^id, model}] -> model
      [] -> nil
    end
  end

  defp model!(id) do
    case lookup_model(id) do
      nil -> raise "journal/ETS inconsistency: model #{id} missing"
      model -> model
    end
  end

  defp owner_key(%Session{} = s), do: {s.owner_id, -datetime_us(s.inserted_at), s.id}
  defp model_key(%Model{} = m), do: {m.session_id, -datetime_us(m.inserted_at), m.id}

  defp bump_seq(session_id, seq) do
    :ets.update_counter(:mnft_counters, {:msg, session_id}, {2, seq}, {{:msg, session_id}, 0})
  end

  defp next_seq(session_id, _count) do
    :ets.update_counter(:mnft_counters, {:msg, session_id}, {2, 2}, {{:msg, session_id}, 0})
  end

  defp new_id, do: :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
  defp datetime_us(%DateTime{} = dt), do: DateTime.to_unix(dt, :microsecond)

  defp struct_from_map(module, map) do
    struct!(
      module,
      map
      |> Enum.map(fn {k, v} -> {String.to_existing_atom(k), decode_value(k, v)} end)
    )
  end

  defp decode_value("inserted_at", iso), do: iso8601(iso)
  defp decode_value("updated_at", iso), do: iso8601(iso)
  defp decode_value("role", role), do: String.to_existing_atom(role)
  defp decode_value(_k, v), do: v

  defp iso8601(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, dt, _} -> dt
      _ -> nil
    end
  end

  defp session_map(%Session{} = s) do
    %{
      "id" => s.id,
      "owner_id" => s.owner_id,
      "title" => s.title,
      "inserted_at" => iso(s.inserted_at),
      "updated_at" => iso(s.updated_at)
    }
  end

  defp message_map(%Message{} = m) do
    %{
      "id" => m.id,
      "session_id" => m.session_id,
      "role" => Atom.to_string(m.role),
      "content" => m.content,
      "code" => m.code,
      "meta" => m.meta,
      "seq" => m.seq,
      "inserted_at" => iso(m.inserted_at),
      "updated_at" => iso(m.updated_at)
    }
  end

  defp model_map(%Model{} = m) do
    %{
      "id" => m.id,
      "session_id" => m.session_id,
      "owner_id" => m.owner_id,
      "message_id" => m.message_id,
      "mesh" => m.mesh,
      "has_glb" => m.has_glb,
      "inserted_at" => iso(m.inserted_at),
      "updated_at" => iso(m.updated_at)
    }
  end

  defp iso(nil), do: nil
  defp iso(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
end
