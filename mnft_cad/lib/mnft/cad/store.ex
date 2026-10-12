defmodule Mnft.Cad.Store do
  @moduledoc """
  The storage boundary. The core ships one adapter — `Mnft.Cad.Store.Ets`
  (ETS + fsynced JSONL journal, zero dependencies); hosts plug in their own
  (the closed SaaS runs an Ecto/Postgres adapter with the same callbacks).

  All reads/writes are scoped by `owner_id`: a session/model id from owner A
  must never be visible to owner B. Selection is `:store` under
  `:mnft_cad, :cad` config.

  Adapters do NOT run the `llm_history` text-massaging (code stripping,
  truncation) — that lives in `Mnft.Cad.llm_history/3` on top of
  `list_messages/1`.
  """

  alias Mnft.Cad.{Message, Model, Session}

  @type session_attrs :: %{optional(:title) => String.t()}

  @type user_attrs :: %{content: String.t(), meta: map()}
  @type assistant_attrs :: %{content: String.t(), code: String.t() | nil, meta: map()}
  @type model_attrs :: %{id: String.t(), mesh: map(), has_glb: boolean()} | nil

  @type turn :: %{
          user_message: Message.t(),
          assistant_message: Message.t(),
          model: Model.t() | nil
        }

  @callback list_sessions(owner_id :: String.t()) :: [Session.t()]
  @callback create_session(owner_id :: String.t(), attrs :: session_attrs()) ::
              {:ok, Session.t()} | {:error, term()}
  @callback get_session(owner_id :: String.t(), session_id :: String.t()) ::
              {:ok, Session.t()} | {:error, :not_found}
  @callback set_title_if_blank(Session.t(), text :: String.t()) ::
              {:ok, Session.t()} | {:ok, :titled} | {:error, term()}
  @callback list_messages(session_id :: String.t()) :: [Message.t()]
  @callback latest_model(session_id :: String.t()) :: Model.t() | nil
  @callback get_model(owner_id :: String.t(), model_id :: String.t()) :: Model.t() | nil
  @callback record_turn(Session.t(), user_attrs(), assistant_attrs(), model_attrs()) ::
              {:ok, turn()} | {:error, term()}
end
