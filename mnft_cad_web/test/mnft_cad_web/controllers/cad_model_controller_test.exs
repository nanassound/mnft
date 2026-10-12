defmodule MnftCadWeb.CadModelControllerTest do
  use MnftCadWeb.ConnCase, async: false

  alias Mnft.Cad

  @owner "owneraaa000000000000000000000000"
  @other "ownerbbb000000000000000000000000"

  setup %{conn: conn} do
    conn = Plug.Test.init_test_session(conn, %{})
    {:ok, session} = Cad.create_session(@owner)

    model = %{
      id: "deadbeefdeadbeef",
      mesh: %{"triangles" => 4, "bbox_mm" => [1.0, 2.0, 3.0], "volume_mm3" => 6.0},
      has_glb: false
    }

    {:ok, %{user_message: _, assistant_message: _, model: model}} =
      Cad.record_turn(
        session,
        %{content: "make", meta: %{}},
        %{content: "done", code: "part = 1", meta: %{}},
        model
      )

    path = Path.join([Mnft.Cad.Config.get(:models_dir), @owner, model.id])
    File.mkdir_p!(path)
    File.write!(Path.join(path, "model.stl"), "solid x\nendsolid x\n")

    %{conn: conn, session: session, model: model}
  end

  test "owner can download their artifact", %{conn: conn} do
    conn = Plug.Conn.put_session(conn, :owner_id, @owner)
    conn = get(conn, ~p"/m/deadbeefdeadbeef/model.stl")
    assert conn.status == 200
    assert conn.resp_body =~ "solid x"
  end

  test "another owner gets 404", %{conn: conn} do
    conn = Plug.Conn.put_session(conn, :owner_id, @other)
    conn = get(conn, ~p"/m/deadbeefdeadbeef/model.stl")
    assert conn.status == 404
  end

  test "unknown filenames and ids are 404", %{conn: conn} do
    conn = Plug.Conn.put_session(conn, :owner_id, @owner)
    assert conn |> get("/m/deadbeefdeadbeef/../model.stl") |> map_response() == 404
    assert conn |> get(~p"/m/nope/model.stl") |> map_response() == 404
    assert conn |> get(~p"/m/deadbeefdeadbeef/secret.txt") |> map_response() == 404
  end

  defp map_response(conn), do: conn.status
end
