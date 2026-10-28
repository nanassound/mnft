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

    engine_ok()
  end

  defp engine_ok do
    EngineFake.set_script([
      %{
        ok: true,
        stage: :exec,
        error: nil,
        artifacts: %{model_id: "abcdef0123456789", stl: "x", step: "x", glb: nil, script: "/tmp/x/model.py"},
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
    assert has_element?(view, "a[href='/m/abcdef0123456789/model.py']")
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

  test "assistant reply renders fenced code as a copyable block", %{conn: conn, session: session} do
    scripted_turn()

    {:ok, view, _html} = live(conn, ~p"/app/s/#{session.id}")
    render_hook(view, "send", %{"message" => "a 30 mm cube", "photos" => [], "current" => nil})

    assert eventually(fn ->
             html = render(view)
             html =~ ~s(<span class="font-mono text-xs text-zinc-400">python</span>)
           end)

    assert has_element?(view, "[phx-hook='CodeCopy']")
    assert render(view) =~ "part = Box(30,30,30)"
    # the raw fence never leaks into the rendered transcript
    refute render(view) =~ "```"
  end

  test "inline_tokens parses bold, italic, and inline code", %{conn: _conn, session: _session} do
    alias MnftCadWeb.CadLive

    assert CadLive.inline_tokens("**Baseplate:** 3.3\" long") == [
             %{kind: :strong, text: "Baseplate:"},
             %{kind: :plain, text: " 3.3\" long"}
           ]

    assert CadLive.inline_tokens("a *slightly* tilted `Box(3)`") == [
             %{kind: :plain, text: "a "},
             %{kind: :em, text: "slightly"},
             %{kind: :plain, text: " tilted "},
             %{kind: :code, text: "Box(3)"}
           ]

    # unclosed markers and arithmetic stay literal
    assert CadLive.inline_tokens("2 * 3 * 4 and a ** stray") == [
             %{kind: :plain, text: "2 * 3 * 4 and a ** stray"}
           ]

    # multibyte neighbours split exactly; markers excluded from inner text
    assert CadLive.inline_tokens("- **Holes:** two Ø3.5 mm *clearance* holes") == [
             %{kind: :plain, text: "- "},
             %{kind: :strong, text: "Holes:"},
             %{kind: :plain, text: " two Ø3.5 mm "},
             %{kind: :em, text: "clearance"},
             %{kind: :plain, text: " holes"}
           ]
  end

  test "assistant prose renders bold and italic", %{conn: conn, session: session} do
    LLMFake.set_script([
      {:ok, %{reply: "Plan:\n**Bold label:** some *emphasis* plus `Box(3)`", reasoning: "", finish_reason: :stop}}
    ])

    engine_ok()

    {:ok, view, _html} = live(conn, ~p"/app/s/#{session.id}")
    render_hook(view, "send", %{"message" => "a part", "photos" => [], "current" => nil})

    assert eventually(fn ->
             html = render(view)
             html =~ "<strong>Bold label:</strong>"
           end)

    html = render(view)
    assert html =~ "<em>emphasis</em>"
    assert html =~ "<code class=\"rounded bg-zinc-200 px-1 font-mono text-[0.85em]\">Box(3)</code>"
    refute html =~ "**"
  end

  test "md_segments splits prose and fenced blocks", %{conn: _conn, session: _session} do
    alias MnftCadWeb.CadLive

    assert CadLive.md_segments("Here.\n```python\npart = Box(30,30,30)\n```") == [
             %{kind: :text, text: "Here."},
             %{kind: :code, lang: "python", code: "part = Box(30,30,30)"}
           ]

    # no fences: single text segment, unchanged
    assert CadLive.md_segments("plain\nreply") == [%{kind: :text, text: "plain\nreply"}]

    # unclosed fence runs to the end; no-language fences get lang nil
    assert CadLive.md_segments("```\nx = 1") == [%{kind: :code, lang: nil, code: "x = 1"}]

    # \r\n fences and bodies are normalized
    assert CadLive.md_segments("a\r\n```python\r\nx=1\r\n```\r\nb") == [
             %{kind: :text, text: "a\r"},
             %{kind: :code, lang: "python", code: "x=1"},
             %{kind: :text, text: "b"}
           ]
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
        artifacts: %{model_id: "abcdef0123456789", stl: "x", step: "x", glb: nil, script: "/tmp/x/model.py"},
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

  # --- uploaded STL turn ----------------------------------------------------------

  @stl_profile %{
    "ok" => true,
    "stats" => %{
      "triangles" => 12,
      "vertices" => 8,
      "bbox_min" => [0.0, 0.0, 0.0],
      "bbox_max" => [10.0, 10.0, 10.0],
      "bbox_size" => [10.0, 10.0, 10.0],
      "volume" => 1000.0,
      "area" => 600.0,
      "watertight" => true,
      "components" => 1
    },
    "sections" => [],
    "renders" => [Base.encode64("render-bytes")]
  }

  def stl_profile_stub(_stl), do: Application.get_env(:mnft_cad_web, :test_stl_profile)

  test "fix rounds update the stage chip and model_ready streams into the viewer", %{
    conn: conn,
    session: session
  } do
    {:ok, view, _html} = live(conn, ~p"/app/s/#{session.id}")

    Mnft.Cad.Events.emit(session.id, "turn_started", %{started_ms: System.system_time(:millisecond)})
    Mnft.Cad.Events.emit(session.id, "repair_started", %{round: 2, rounds: 3})

    assert eventually(fn -> render(view) =~ "fixing (round 2/3)" end)

    Mnft.Cad.Events.emit(session.id, "model_ready", %{
      id: "abcdef0123456789",
      has_glb: true,
      script_file: "model.py",
      mesh: %{"bbox_mm" => [30.0, 30.0, 30.0], "triangles" => 12, "volume_mm3" => 27_000.0}
    })

    assert eventually(fn ->
             html = render(view)
             html =~ "/m/abcdef0123456789/model.stl" && html =~ "bbox 30.0 × 30.0 × 30.0 mm · 12 triangles"
           end)
  end

  test "STL turn: analysis runs, bubble shows the STL chip, turn completes", %{
    conn: conn,
    session: session
  } do
    snapshot = Mnft.Cad.Config.all()

    cfg = Keyword.put(snapshot, :stl_profile_fun, {__MODULE__, :stl_profile_stub, []})
    Application.put_env(:mnft_cad, :cad, cfg)
    Application.put_env(:mnft_cad_web, :test_stl_profile, {:ok, @stl_profile})

    on_exit(fn ->
      Application.put_env(:mnft_cad, :cad, snapshot)
      Application.delete_env(:mnft_cad_web, :test_stl_profile)
    end)

    scripted_turn()

    {:ok, view, _html} = live(conn, ~p"/app/s/#{session.id}")

    stl = %{
      "data_url" => "data:model/stl;base64," <> Base.encode64("stl-bytes"),
      "name" => "part.stl",
      "size" => 10
    }

    render_hook(view, "send", %{
      "message" => "reconstruct this",
      "photos" => [],
      "stl" => stl,
      "current" => nil
    })

    assert eventually(fn -> has_element?(view, "#model-info") end)

    html = render(view)
    assert html =~ "STL · part.stl · 0.0 MB"
    assert html =~ "reconstruct this"

    # persisted user meta carries the STL metadata alongside the finished turn
    user_msg = Cad.list_messages(session.id) |> hd()
    assert user_msg.meta["stl"]["name"] == "part.stl"
    assert user_msg.meta["stl"]["triangles"] == 12
  end
end
