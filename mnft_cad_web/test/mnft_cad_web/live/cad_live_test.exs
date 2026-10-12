defmodule MnftCadWeb.CadLiveTest do
  use MnftCadWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Mnft.Cad
  alias Mnft.Cad.{EngineFake, LLMFake}

  @owner "testowner0000000000000000000000"

  setup %{conn: conn} do
    start_supervised!(LLMFake)
    start_supervised!(EngineFake)
    LLMFake.set_script([])
    EngineFake.set_script([])
    conn = Plug.Test.init_test_session(conn, %{})
    conn = Plug.Conn.put_session(conn, :owner_id, @owner)
    {:ok, session} = Cad.create_session(@owner)
    %{conn: conn, session: session}
  end

  defp scripted_turn do
    LLMFake.set_script([
      {:ok,
       %{
         reply: "Here.\n```python\npart = Box(30,30,30)\n```",
         reasoning: "",
         finish_reason: :stop
       }}
    ])

    EngineFake.set_script([
      %{
        ok: true,
        stage: :exec,
        error: nil,
        artifacts: %{model_id: "abcdef0123456789", stl: "x", step: "x", glb: nil},
        mesh: %{"triangles" => 12, "bbox_mm" => [30.0, 30.0, 30.0], "volume_mm3" => 27_000.0},
        exec_ms: 5
      }
    ])
  end

  test "index lists sessions and creates a new one", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/app")
    assert has_element?(view, "#new-session")
    view |> element("#new-session") |> render_click()
    {path, _flash} = assert_redirect(view)
    assert path =~ "/app/s/"
  end

  test "another owner's session is not reachable", %{conn: conn, session: session} do
    other_conn =
      build_conn()
      |> Plug.Test.init_test_session(%{})
      |> Plug.Conn.put_session(:owner_id, "someoneelse00000000000000")

    assert {:error, {:live_redirect, %{to: "/app"}}} = live(other_conn, ~p"/app/s/#{session.id}")
    assert {:ok, _view, _} = live(conn, ~p"/app/s/#{session.id}")
  end

  test "cad page mounts for the cookie owner and renders", %{conn: conn, session: session} do
    {:ok, view, html} = live(conn, ~p"/app/s/#{session.id}")
    assert html =~ "Describe a part to begin"
    assert has_element?(view, "#chat-form")
    assert has_element?(view, "#cad-viewer")
  end

  test "send runs a scripted turn end-to-end and shows the model", %{conn: conn, session: session} do
    scripted_turn()

    {:ok, view, _html} = live(conn, ~p"/app/s/#{session.id}")
    render_hook(view, "send", %{"message" => "a 30 mm cube", "photos" => [], "current" => nil})

    assert eventually(fn -> has_element?(view, "#model-info") end)
    assert render(view) =~ "bbox 30.0 × 30.0 × 30.0 mm · 12 triangles"
    assert has_element?(view, "a[href='/m/abcdef0123456789/model.stl']")
    refute has_element?(view, "#turn-status")

    # the turn was persisted: user + assistant messages, model row
    assert eventually(fn ->
             [%{role: :assistant} | _] = Enum.reverse(Cad.list_messages(session.id))
             Cad.latest_model(session.id) != nil
           end)

    # annotation toolbar renders alongside the model
    assert has_element?(view, "#anno-pen")
    assert has_element?(view, "#anno-copy")
  end

  test "turn events broadcast through PubSubBridge reach the LiveView", %{
    conn: conn,
    session: session
  } do
    scripted_turn()

    {:ok, view, _html} = live(conn, ~p"/app/s/#{session.id}")
    render_hook(view, "send", %{"message" => "a 30 mm cube", "photos" => [], "current" => nil})

    # llm_started turns the stage indicator to "thinking" before completion
    assert eventually(fn ->
             html = render(view)
             html =~ "thinking" or html =~ "bbox 30.0"
           end)

    assert eventually(fn -> has_element?(view, "#model-info") end)
  end

  test "reopening a part mid-turn restores the pending message and timer", %{
    conn: conn,
    session: session
  } do
    LLMFake.set_script([
      {:hold,
       {:ok,
        %{
          reply: "Here.\n```python\npart = Box(30,30,30)\n```",
          reasoning: "",
          finish_reason: :stop
        }}}
    ])

    EngineFake.set_script([
      %{
        ok: true,
        stage: :exec,
        error: nil,
        artifacts: %{model_id: "abcdef0123456789", stl: "x", step: "x", glb: nil},
        mesh: %{"triangles" => 12, "bbox_mm" => [30.0, 30.0, 30.0], "volume_mm3" => 27_000.0},
        exec_ms: 5
      }
    ])

    {:ok, view, _html} = live(conn, ~p"/app/s/#{session.id}")
    render_hook(view, "send", %{"message" => "a 30 mm cube", "photos" => [], "current" => nil})

    assert eventually(fn -> LLMFake.held() != [] end)

    # Re-open the same part on a fresh conn, built exactly like setup does.
    conn2 =
      build_conn()
      |> Plug.Test.init_test_session(%{})
      |> Plug.Conn.put_session(:owner_id, @owner)

    {:ok, view2, html2} = live(conn2, ~p"/app/s/#{session.id}")

    # the in-flight user message renders in the initial HTML (no connected? gate)
    assert html2 =~ "a 30 mm cube"
    assert has_element?(view2, "#turn-status")
    assert render(view2) =~ "working"

    # the timer continues from the real start, not from the remount
    Process.sleep(1100)
    status_html = render(element(view2, "#turn-status"))
    [elapsed] = Regex.run(~r/(\d+)s/, status_html, capture: :all_but_first)
    assert String.to_integer(elapsed) >= 1

    LLMFake.release(hd(LLMFake.held()))

    assert eventually(fn -> not has_element?(view2, "#turn-status") end)
    assert render(view2) =~ "a 30 mm cube"
    assert has_element?(view2, "#model-info")
  end

  defp eventually(fun, tries \\ 100) do
    cond do
      fun.() -> true
      tries == 0 -> false
      true -> Process.sleep(30) && eventually(fun, tries - 1)
    end
  end
end
