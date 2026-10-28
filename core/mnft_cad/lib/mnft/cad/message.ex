defmodule Mnft.Cad.Message do
  @moduledoc """
  One chat turn side. `meta` carries response bookkeeping (llm_ms/exec_ms/
  model/vision/repaired/code_missing/error/error_detail/code_failed) plus
  photo METADATA ONLY — uploaded image bytes are memory-only and must never
  reach storage or the logs.

  `role` is `:user` or `:assistant`. `code` is set on assistant messages that
  carried a generated script. `seq` is the per-session ordering number
  (storage detail; the default store keys messages by it).
  """

  defstruct [:id, :session_id, :role, :content, :code, :meta, :seq, :inserted_at, :updated_at]

  @type role :: :user | :assistant

  @type t :: %__MODULE__{
          id: String.t(),
          session_id: String.t(),
          role: role(),
          content: String.t(),
          code: String.t() | nil,
          meta: map(),
          seq: non_neg_integer() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }
end
