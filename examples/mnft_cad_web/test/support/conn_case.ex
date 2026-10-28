defmodule MnftCadWeb.ConnCase do
  @moduledoc """
  Test case for requests through the endpoint. Sets up a signed session
  cookie carrying a stable anonymous owner id.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      @endpoint MnftCadWeb.Endpoint

      use MnftCadWeb, :verified_routes

      import Plug.Conn
      import Phoenix.ConnTest
      import MnftCadWeb.ConnCase
    end
  end

  setup _tags do
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end

  @doc """
  Gives the connection a session with a fixed anonymous owner id, and
  returns that id.
  """
  def with_owner(%Plug.Conn{} = conn, owner_id \\ "testowner0000000000000000000000") do
    Plug.Conn.put_session(conn, :owner_id, owner_id)
    |> Plug.Conn.assign(:owner_id, owner_id)
    |> then(&{&1, owner_id})
  end
end
