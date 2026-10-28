defmodule Mnft.Cad.Session do
  @moduledoc """
  One chat thread = one CAD session. A Jido agent runs per session.

  Plain struct — storage ownership belongs to the `Mnft.Cad.Store` adapter.
  `owner_id` is an opaque host-supplied string (a user id, an anonymous
  session id, ...); the core never authenticates, it only scopes by it.
  """

  defstruct [:id, :owner_id, :title, :inserted_at, :updated_at]

  @type t :: %__MODULE__{
          id: String.t(),
          owner_id: String.t(),
          title: String.t(),
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }
end
