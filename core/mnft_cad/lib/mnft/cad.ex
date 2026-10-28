defmodule Mnft.Cad do
  @moduledoc """
  The core's public facade: session/message/model operations through the
  configured `Mnft.Cad.Store`, plus the module seams (`store/0`, `engine/0`,
  `llm_module/0`).

  Everything is scoped by an opaque `owner_id` — the core never authenticates.
  """

  alias Mnft.Cad.Config
  alias Mnft.Cad.{Message, Model, Session, Store}

  # --- seams -------------------------------------------------------------------

  @spec store() :: module()
  def store, do: Config.get(:store, Mnft.Cad.Store.Ets)

  @spec engine() :: module()
  def engine, do: Config.get(:engine, Mnft.Cad.Engines.Build123d)

  @spec llm_module() :: module()
  def llm_module, do: Config.get(:llm_module, Mnft.Cad.LLM)

  @spec references_module() :: module()
  def references_module, do: Config.get(:references_module, Mnft.Cad.References)

  # --- sessions ----------------------------------------------------------------

  @spec list_sessions(String.t()) :: [Session.t()]
  def list_sessions(owner_id), do: store().list_sessions(owner_id)

  @spec create_session(String.t(), Store.session_attrs()) :: {:ok, Session.t()} | {:error, term()}
  def create_session(owner_id, attrs \\ %{}), do: store().create_session(owner_id, attrs)

  @doc "Raises `ArgumentError` unless the session belongs to `owner_id`."
  @spec get_session!(String.t(), String.t()) :: Session.t()
  def get_session!(owner_id, session_id) do
    case store().get_session(owner_id, session_id) do
      {:ok, session} -> session
      {:error, :not_found} -> raise ArgumentError, "session not found for this owner"
    end
  end

  @doc "Set the session title from the first user message; no-op once titled."
  @spec set_title_if_blank(Session.t(), String.t()) ::
          {:ok, Session.t()} | {:ok, :titled} | {:error, term()}
  def set_title_if_blank(session, text), do: store().set_title_if_blank(session, text)

  # --- messages ----------------------------------------------------------------

  @spec list_messages(String.t()) :: [Message.t()]
  def list_messages(session_id), do: store().list_messages(session_id)

  @doc """
  History for the LLM: text-only user/assistant contents, oldest first,
  newest `limit` entries. Only the NEWEST assistant message keeps its fenced
  code — it is the live artifact; older copies are replaced with
  `[earlier code elided]` (replaying every past code block anchored the model
  on stale geometry). Each content is truncated to `max_chars`.
  """
  @spec llm_history(String.t(), pos_integer(), pos_integer()) :: [
          %{role: :user | :assistant, content: String.t()}
        ]
  def llm_history(session_id, limit \\ 20, max_chars \\ 8_000) do
    entries =
      session_id
      |> store().list_messages()
      |> Enum.filter(&(&1.role in [:user, :assistant]))
      |> Enum.take(-limit)

    newest_assistant_idx =
      entries
      |> Enum.with_index()
      |> Enum.reduce(nil, fn
        {%{role: :assistant}, i}, _acc -> i
        _entry, acc -> acc
      end)

    Enum.map(Enum.with_index(entries), fn {%{role: role, content: content, meta: meta}, idx} ->
      content =
        if role == :assistant and idx != newest_assistant_idx,
          do: code_gen().strip_code_blocks(content),
          else: content

      content = String.slice(content, 0, max_chars)

      # Fetched reference text re-enters after the slice so it is never cut:
      # a later (or post-restart) turn must see the extracted dimensions
      # instead of a bare URL it cannot read.
      content =
        if role == :user,
          do: append_references(content, meta),
          else: content

      %{role: role, content: content}
    end)
  end

  defp append_references(content, meta) do
    refs = (is_map(meta) && Map.get(meta, "references")) || []

    if is_list(refs) do
      Enum.reduce(refs, content, fn
        %{"url" => url, "text" => text}, acc when is_binary(url) and is_binary(text) ->
          acc <> "\n\n[Reference datasheet text extracted from " <> url <> "]\n" <> text

        _ref, acc ->
          acc
      end)
    else
      content
    end
  end

  # --- models ------------------------------------------------------------------

  @spec latest_model(String.t()) :: Model.t() | nil
  def latest_model(session_id), do: store().latest_model(session_id)

  @doc "Fetch a model for download; `nil` unless it belongs to `owner_id`."
  @spec get_model(String.t(), String.t()) :: Model.t() | nil
  def get_model(owner_id, model_id), do: store().get_model(owner_id, model_id)

  # --- turn persistence ----------------------------------------------------------

  @doc """
  Persist one completed turn atomically: the user message, the assistant
  message, and (on a successful build) the model row.
  """
  @spec record_turn(Session.t(), Store.user_attrs(), Store.assistant_attrs(), Store.model_attrs()) ::
          {:ok, Store.turn()} | {:error, term()}
  def record_turn(session, user_attrs, assistant_attrs, model_attrs),
    do: store().record_turn(session, user_attrs, assistant_attrs, model_attrs)

  defp code_gen, do: Mnft.Cad.CodeGen
end
