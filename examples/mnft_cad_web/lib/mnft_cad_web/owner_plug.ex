defmodule MnftCadWeb.OwnerPlug do
  @moduledoc """
  Anonymous ownership: assigns `:owner_id` from the signed session cookie,
  minting (and persisting) a random id when absent. No accounts — the cookie
  IS the owner.

  Also provides an `on_mount` hook so LiveViews outside the browser
  pipeline (the live_session) get the same assign from the connect params'
  session data.
  """

  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    owner_id = get_session(conn, :owner_id)

    cond do
      is_binary(owner_id) and owner_id != "" ->
        assign(conn, :owner_id, owner_id)

      true ->
        owner_id = new_owner_id()
        conn |> put_session(:owner_id, owner_id) |> assign(:owner_id, owner_id)
    end
  end

  def on_mount(:assign_owner, _params, session, socket) do
    owner_id =
      case session[:owner_id] || session["owner_id"] do
        id when is_binary(id) and id != "" -> id
        _ -> new_owner_id()
      end

    {:cont, Phoenix.Component.assign(socket, :owner_id, owner_id)}
  end

  defp new_owner_id, do: :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
end
